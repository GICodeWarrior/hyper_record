unless defined?(ActiveRecord::ConnectionAdapters::AbstractAdapter)
  # running into some situations where rails has already loaded this, without
  # require realizing it, and loading again is unsafe (alias_method_chain is a
  # great way to create infinite recursion loops)
  require 'active_record/connection_adapters/abstract_adapter'
end
require 'active_record/connection_adapters/qualified_column'
require 'active_record/connection_adapters/hyper_table_definition'

module ActiveRecord
  class Base
    def self.require_hypertable_thrift_client
      # Include the hypertools driver if one hasn't already been loaded
      unless defined? Hypertable::ThriftClient
        gem 'hypertable-thrift-client'
        require_dependency 'thrift_client'
      end
    end

    def self.hypertable_connection(config)
      config = config.symbolize_keys
      require_hypertable_thrift_client

      raise "Hypertable config missing :host in database.yml" if !config[:host]

      host = config[:host] || 'localhost'
      port = config[:port] || 38088
      timeout_ms = config[:timeout] || 20000

      connection = Hypertable::ThriftClient.new(host, port, timeout_ms)

      ConnectionAdapters::HypertableAdapter.new(connection, logger, config)
    end
  end

  module ConnectionAdapters
    class HypertableAdapter < AbstractAdapter
      @@read_latency = 0.0
      @@write_latency = 0.0
      @@cells_read = 0
      cattr_accessor :read_latency, :write_latency, :cells_read

      # Used by retry_on_connection_error() to determine whether to retry
      @retry_on_failure = true
      attr_accessor :retry_on_failure

      def initialize(connection, logger, config)
        super(connection, logger)
        @config = config
        @hypertable_column_names = {}
      end

      def self.reset_timing
        @@read_latency = 0.0
        @@write_latency = 0.0
        @@cells_read = 0
      end

      def self.get_timing
        [@@read_latency, @@write_latency, @@cells_read]
      end

      def convert_select_columns_to_array_of_columns(s, columns=nil)
        select_rows = s.class == String ? s.split(',').map{|s| s.strip} : s
        select_rows = select_rows.reject{|s| s == '*'}

        if select_rows.empty? and !columns.blank?
          for c in columns
            next if c.name == 'ROW' # skip over the ROW key, always included
            if c.is_a?(QualifiedColumn)
              for q in c.qualifiers
                select_rows << qualified_column_name(c.name, q.to_s)
              end
            else
              select_rows << c.name
            end
          end
        end

        select_rows
      end

      def adapter_name
        'Hypertable'
      end

      def supports_migrations?
        true
      end

      def native_database_types
        {
          :string      => { :name => "varchar", :limit => 255 }
        }
      end

      def sanitize_conditions(options)
        case options[:conditions]
          when Hash
            # requires Hypertable API to support query by arbitrary cell value
            raise "HyperRecord does not support specifying conditions by Hash"
          when NilClass
            # do nothing
          else
            raise "Only hash conditions are supported"
        end
      end

      def execute_with_options(options)
        # Rows can be specified using a number of different options:
        # row ranges (start_row and end_row)
        options[:row_intervals] ||= []

        if options[:row_keys]
          options[:row_keys].flatten.each do |rk|
            row_interval = Hypertable::ThriftGen::RowInterval.new
            row_interval.start_row = rk
            row_interval.start_inclusive = true
            row_interval.end_row = rk
            row_interval.end_inclusive = true
            options[:row_intervals] << row_interval
          end
        elsif options[:start_row]
          raise "missing :end_row" if !options[:end_row]

          options[:start_inclusive] = options.has_key?(:start_inclusive) ? options[:start_inclusive] : true
          options[:end_inclusive] = options.has_key?(:end_inclusive) ? options[:end_inclusive] : true

          row_interval = Hypertable::ThriftGen::RowInterval.new
          row_interval.start_row = options[:start_row]
          row_interval.start_inclusive = options[:start_inclusive]
          row_interval.end_row = options[:end_row]
          row_interval.end_inclusive = options[:end_inclusive]
          options[:row_intervals] << row_interval
        end

        sanitize_conditions(options)

        select_rows = convert_select_columns_to_array_of_columns(options[:select], options[:columns])

        t1 = Time.now
        table_name = options[:table_name]
        scan_spec = convert_options_to_scan_spec(options)

        # Use native array method (get_cells_as_arrays) for cell retrieval - 
        # much faster than get_cells that returns Hypertable::ThriftGen::Cell
        # objects.
        # [
        #   ["page_1", "name", "", "LOLcats and more", "1237331693147619001"], 
        #   ["page_1", "url", "", "http://...", "1237331693147619002"]
        # ]
        cells = retry_on_connection_error {
          @connection.get_cells_as_arrays(table_name, scan_spec)
        }

        # Capture performance metrics
        @@read_latency += Time.now - t1
        @@cells_read += cells.length

        cells
      end

      # Exceptions generated by Thrift IDL do not set a message.
      # This causes a lot of problems for Rails which expects a String
      # value and throws exception when it encounters NilClass.
      # Unfortunately, you cannot assign a message to exceptions so define
      # a singleton to accomplish same goal.
      def handle_thrift_exceptions_with_missing_message
        begin
          yield
        rescue Exception => err
          if !err.message
            if err.respond_to?("message=")
              err.message = err.what || ''
            else
              def err.message
                self.what || ''
              end
            end
          end

          raise err
        end
      end

      # Attempt to reconnect to the Thrift Broker once before aborting.
      # This ensures graceful recovery in the case that the Thrift Broker
      # goes down and then comes back up.
      def retry_on_connection_error
        @retry_on_failure = true
        begin
          handle_thrift_exceptions_with_missing_message { yield }
        rescue Thrift::TransportException, IOError, Thrift::ApplicationException => err
          if @retry_on_failure
            @retry_on_failure = false
            @connection.close
            @connection.open
            retry
          else
            raise err
          end
        end
      end

      def convert_options_to_scan_spec(options={})
        scan_spec = Hypertable::ThriftGen::ScanSpec.new
        options[:revs] ||= 1
        options[:return_deletes] ||= false

        for key in options.keys
          case key.to_sym
            when :row_intervals
              scan_spec.row_intervals = options[key]
            when :cell_intervals
              scan_spec.cell_intervals = options[key]
            when :start_time
              scan_spec.start_time = options[key]
            when :end_time
              scan_spec.end_time = options[key]
            when :limit
              scan_spec.row_limit = options[key]
            when :revs
              scan_spec.revs = options[key]
            when :return_deletes
              scan_spec.return_deletes = options[key]
            when :select
              # Columns listed here can be column families only (not
              # column qualifiers) at this time.
              requested_columns = options[key].is_a?(String) ? options[key].split(',').map{|s| s.strip} : options[key]
              scan_spec.columns = requested_columns.map do |column|
                status, family, qualifier = is_qualified_column_name?(column)
                family
              end.uniq
            when :table_name, :start_row, :end_row, :start_inclusive, :end_inclusive, :select, :columns, :row_keys, :conditions, :include, :readonly
              # ignore
            else
              raise "Unrecognized scan spec option: #{key}"
          end
        end

        scan_spec
      end

      def execute(hql, name=nil)
        log(hql, name) {
          retry_on_connection_error { @connection.hql_query(hql) }
        }
      end

      # Column Operations

      # Returns array of column objects for table associated with this class.
      # Hypertable allows columns to include dashes in the name.  This doesn't
      # play well with Ruby (can't have dashes in method names), so we must
      # maintain a mapping of original column names to Ruby-safe names.
      def columns(table_name, name = nil)#:nodoc:
        # Each table always has a row key called 'ROW'
        columns = [
          Column.new('ROW', '')
        ]
        schema = describe_table(table_name)
        doc = REXML::Document.new(schema)
        column_families = doc.elements['Schema/AccessGroup[@name="default"]'].elements.to_a

        @hypertable_column_names[table_name] ||= {}
        for cf in column_families
          column_name = cf.elements['Name'].text
          rubified_name = rubify_column_name(column_name)
          @hypertable_column_names[table_name][rubified_name] = column_name
          columns << new_column(rubified_name, '')
        end

        columns
      end

      def remove_column_from_name_map(table_name, name)
        @hypertable_column_names[table_name].delete(rubify_column_name(name))
      end

      def add_column_to_name_map(table_name, name)
        @hypertable_column_names[table_name][rubify_column_name(name)] = name
      end

      def add_qualified_column(table_name, column_family, qualifiers=[], default='', sql_type=nil, null=true)
        qc = QualifiedColumn.new(column_family, default, sql_type, null)
        qc.qualifiers = qualifiers
        qualifiers.each{|q| add_column_to_name_map(table_name, qualified_column_name(column_family, q))}
        qc
      end

      def new_column(column_name, default_value='')
        Column.new(rubify_column_name(column_name), default_value)
      end

      def qualified_column_name(column_family, qualifier=nil)
        [column_family, qualifier].compact.join(':')
      end

      def rubify_column_name(column_name)
        column_name.to_s.gsub(/-+/, '_')
      end

      def is_qualified_column_name?(column_name)
        column_family, qualifier = column_name.split(':', 2)
        if qualifier
          [true, column_family, qualifier]
        else
          [false, column_name, nil]
        end
      end

      # Schema alterations

      def rename_column(table_name, column_name, new_column_name)
        raise "rename_column operation not supported by Hypertable."
      end

      def change_column(table_name, column_name, new_column_name)
        raise "change_column operation not supported by Hypertable."
      end

      def create_table_hql(table_name, options={})
        table_definition = HyperTableDefinition.new(self)

        yield table_definition

        if options[:force] && table_exists?(table_name)
          drop_table(table_name, options)
        end

        create_sql = [ "CREATE TABLE #{quote_table_name(table_name)} (" ]
        column_sql = []
        for col in table_definition.columns
          column_sql << [
            quote_table_name(col.name),
            col.max_versions ? "MAX_VERSIONS=#{col.max_versions}" : ''
          ].join(' ')
        end
        create_sql << column_sql.join(', ')

        create_sql << ") #{options[:options]}"
        create_sql.join(' ').strip
      end

      def create_table(table_name, options = {})
        execute(create_table_hql(table_name, options))
      end

      def drop_table(table_name, options = {})
        retry_on_connection_error {
          @connection.drop_table(table_name, options[:if_exists] || false)
        }
      end

      def rename_table(table_name, options = {})
        raise "rename_table operation not supported by Hypertable."
      end

      def change_column_default(table_name, column_name, default)
        raise "change_column_default operation not supported by Hypertable."
      end

      def change_column_null(table_name, column_name, null, default = nil)
        raise "change_column_null operation not supported by Hypertable."
      end

      def add_column(table_name, column_name, type=:string, options = {})
        hql = [ "ALTER TABLE #{quote_table_name(table_name)} ADD (" ]
        hql << quote_column_name(column_name)
        hql << "MAX_VERSIONS=#{options[:max_versions]}" if !options[:max_versions].blank?
        hql << ")"
        execute(hql.join(' '))
      end

      def add_column_options!(hql, options)
        hql << " MAX_VERSIONS =1 #{quote(options[:default], options[:column])}" if options_include_default?(options)
        # must explicitly check for :null to allow change_column to work on migrations
        if options[:null] == false
          hql << " NOT NULL"
        end
      end

      def remove_column(table_name, *column_names)
        column_names.flatten.each do |column_name|
          execute "ALTER TABLE #{quote_table_name(table_name)} DROP(#{quote_column_name(column_name)})"
        end
      end
      alias :remove_columns :remove_column

      def quote(value, column = nil)
        case value
          when NilClass then ''
          when String then value
          else super(value, column)
        end
      end

      def quote_column_name(name)
        "'#{name}'"
      end

      def quote_column_name_for_table(name, table_name)
        quote_column_name(hypertable_column_name(name, table_name))
      end

      def hypertable_column_name(name, table_name, declared_columns_only=false)
        n = @hypertable_column_names[table_name][name]
        n ||= name if !declared_columns_only
        n
      end

      def describe_table(table_name)
        retry_on_connection_error {
          @connection.get_schema(table_name)
        }
      end

      def tables(name=nil)
        retry_on_connection_error {
          @connection.get_tables
        }
      end

      def write_cells(table_name, cells, mutator=nil)
        return if cells.blank?

        retry_on_connection_error {
          local_mutator_created = !mutator

          begin
            t1 = Time.now
            mutator ||= @connection.open_mutator(table_name)
            @connection.set_cells_as_arrays(mutator, cells)
          ensure
            @connection.close_mutator(mutator, true) if local_mutator_created
            @@write_latency += Time.now - t1
          end
        }
      end

      # Cell passed in as [row_key, column_name, value]
      # return a Hypertable::ThriftGen::Cell object which is required
      # if the cell requires a flag on write (delete operations)
      def thrift_cell_from_native_array(array)
        cell = Hypertable::ThriftGen::Cell.new
        cell.row_key = array[0]
        cell.column_family = array[1]
        cell.column_qualifier = array[2] if !array[2].blank?
        cell.value = array[3] if array[3]
        cell.timestamp = array[4] if array[4]
        cell
      end

      # Create native array format for cell.
      # ["row_key", "column_family", "column_qualifier", "value"],
      def cell_native_array(row_key, column_family, column_qualifier, value=nil, timestamp=nil)
        [
          row_key.to_s,
          column_family.to_s,
          column_qualifier.to_s,
          value.to_s
        ]
      end

      def delete_cells(table_name, cells)
        t1 = Time.now

        retry_on_connection_error {
          @connection.with_mutator(table_name) do |mutator|
            thrift_cells = cells.map{|c|
              cell = thrift_cell_from_native_array(c)
              cell.flag = Hypertable::ThriftGen::CellFlag::DELETE_CELL
              cell
            }
            @connection.set_cells(mutator, thrift_cells)
          end
        }

        @@write_latency += Time.now - t1
      end

      def delete_rows(table_name, row_keys)
        t1 = Time.now
        cells = row_keys.map do |row_key|
          cell = Hypertable::ThriftGen::Cell.new
          cell.row_key = row_key
          cell.flag = Hypertable::ThriftGen::CellFlag::DELETE_ROW
          cell
        end

        retry_on_connection_error {
          @connection.with_mutator(table_name) do |mutator|
            @connection.set_cells(mutator, cells)
          end
        }

        @@write_latency += Time.now - t1
      end

      def insert_fixture(fixture, table_name)
        fixture_hash = fixture.to_hash
        timestamp = fixture_hash.delete('timestamp')
        row_key = fixture_hash.delete('ROW')
        cells = []
        fixture_hash.keys.each do |k|
          column_name, column_family = k.split(':', 2)
          cells << cell_native_array(row_key, column_name, column_family, fixture_hash[k], timestamp)
        end
        write_cells(table_name, cells)
      end

      # Mutator methods

      def open_mutator(table_name)
        @connection.open_mutator(table_name)
      end

      def close_mutator(mutator, flush=true)
        @connection.close_mutator(mutator, flush)
      end

      def flush_mutator(mutator)
        @connection.flush_mutator(mutator)
      end

      private

        def select(hql, name=nil)
          # TODO: need hypertools run_hql to return result set
          raise "not yet implemented"
        end
    end
  end
end
