require 'data_objects'
require 'dm-core'

module DataMapper
  module Adapters

    # DataObjectsAdapter is the base class for all adapers for relational
    # databases. If you want to add support for a new RDBMS, it makes
    # sense to make your adapter class inherit from this class.
    #
    # By inheriting from DataObjectsAdapter, you get a copy of all the
    # standard sub-modules (Quoting, Coersion and Queries) in your own Adapter.
    # You can extend and overwrite these copies without affecting the originals.
    class DataObjectsAdapter < AbstractAdapter
      extend Chainable
      extend Deprecate

      deprecate :query, :select

      # Retrieve results using an SQL SELECT statement
      #
      # @param [String] statement
      #   the SQL SELECT statement
      # @param [Array] *bind_values
      #   optional bind values to merge into the statement
      #
      # @return [Array]
      #   if fields > 1, return an Array of Struct objects
      #   if fields == 1, return an Array of objects
      #
      # @api public
      def select(statement, *bind_values)
        with_connection do |connection|
          reader = connection.create_command(statement).execute_reader(*bind_values)
          fields = reader.fields

          begin
            if fields.size > 1
              select_fields(reader, fields)
            else
              select_field(reader)
            end
          ensure
            reader.close
          end
        end
      end

      # Execute non-SELECT SQL query
      #
      # @param [String] statement
      #   the SQL statement
      # @param [Array] *bind_values
      #   optional bind values to merge into the statement
      #
      # @return [DataObjects::Result]
      #   result with number of affected rows, and insert id if any
      #
      # @api public
      def execute(statement, *bind_values)
        with_connection do |connection|
          command = connection.create_command(statement)
          command.execute_non_query(*bind_values)
        end
      end

      # For each model instance in resources, issues an SQL INSERT
      # (or equivalent) statement to create a new record in the data store for
      # the instance
      #
      # Note that this method does not update the identity map. If a plugin
      # needs to use an adapter directly, it is up to plugin developer to
      # keep the identity map up to date.
      #
      # @param [Enumerable(Resource)] resources
      #   The list of resources (model instances) to create
      #
      # @return [Integer]
      #   The number of records that were actually saved into the database
      #
      # @api semipublic
      def create(resources)
        name = self.name

        resources.each do |resource|
          model      = resource.model
          serial     = model.serial(name)
          attributes = resource.dirty_attributes

          properties  = []
          bind_values = []

          # make the order of the properties consistent
          model.properties(name).each do |property|
            next unless attributes.key?(property)

            bind_value = attributes[property]

            # skip insering NULL for columns that are serial or without a default
            next if bind_value.nil? && (property.serial? || !property.default?)

            # if serial is being set explicitly, do not set it again
            if property.equal?(serial)
              serial = nil
            end

            properties  << property
            bind_values << bind_value
          end

          statement = insert_statement(model, properties, serial)

          result = with_connection do |connection|
            connection.create_command(statement).execute_non_query(*bind_values)
          end

          if result.affected_rows == 1 && serial
            serial.set!(resource, result.insert_id)
          end
        end
      end

      # Constructs and executes SELECT query, then instantiates
      # one or many object from result set.
      #
      # @param [Query] query
      #   composition of the query to perform
      #
      # @return [Array]
      #   result set of the query
      #
      # @api semipublic
      def read(query)
        fields = query.fields
        types  = fields.map { |property| property.primitive }

        statement, bind_values = select_statement(query)

        records = []

        with_connection do |connection|
          command = connection.create_command(statement)
          command.set_types(types)

          reader = command.execute_reader(*bind_values)

          begin
            while reader.next!
              records << fields.zip(reader.values).to_hash
            end
          ensure
            reader.close
          end
        end

        records
      end

      # Constructs and executes UPDATE statement for given
      # attributes and a query
      #
      # @param [Hash(Property => Object)] attributes
      #   hash of attribute values to set, keyed by Property
      # @param [Collection] collection
      #   collection of records to be updated
      #
      # @return [Integer]
      #   the number of records updated
      #
      # @api semipublic
      def update(attributes, collection)
        query = collection.query

        properties  = []
        bind_values = []

        # make the order of the properties consistent
        query.model.properties(name).each do |property|
          next unless attributes.key?(property)
          properties  << property
          bind_values << attributes[property]
        end

        statement, conditions_bind_values = update_statement(properties, query)

        bind_values.concat(conditions_bind_values)

        with_connection do |connection|
          connection.create_command(statement).execute_non_query(*bind_values)
        end.affected_rows
      end

      # Constructs and executes DELETE statement for given query
      #
      # @param [Collection] collection
      #   collection of records to be deleted
      #
      # @return [Integer]
      #   the number of records deleted
      #
      # @api semipublic
      def delete(collection)
        query = collection.query
        statement, bind_values = delete_statement(query)

        with_connection do |connection|
          connection.create_command(statement).execute_non_query(*bind_values)
        end.affected_rows
      end

      protected

      # @api private
      def normalized_uri
        @normalized_uri ||=
          begin
            query = @options.except(:adapter, :user, :password, :host, :port, :path, :fragment, :scheme, :query, :username, :database)
            query = nil if query.empty?

            # Better error message in case port is no Numeric value
            port = @options[:port].nil? ? nil : @options[:port].to_int

            DataObjects::URI.new(
              @options[:adapter],
              @options[:user] || @options[:username],
              @options[:password],
              @options[:host],
              port,
              @options[:path] || @options[:database],
              query,
              @options[:fragment]
            ).freeze
          end
      end

      chainable do
        protected

        # Instantiates new connection object
        #
        # @api semipublic
        def open_connection
          DataObjects::Connection.new(normalized_uri)
        end

        # Takes connection and closes it
        #
        # @api semipublic
        def close_connection(connection)
          connection.close if connection.respond_to?(:close)
        end
      end

      private

      # @api public
      def initialize(name, uri_or_options)
        super

        # Default the driver-specific logger to DataMapper's logger
        if driver_module = DataObjects.const_get(normalized_uri.scheme.capitalize)
          driver_module.logger = DataMapper.logger if driver_module.respond_to?(:logger=)
        end
      end

      # @api private
      def with_connection
        yield connection = open_connection
      rescue Exception => exception
        DataMapper.logger.error(exception.to_s) if DataMapper.logger
        raise
      ensure
        close_connection(connection)
      end

      # @api private
      def select_fields(reader, fields)
        fields = fields.map { |field| DataMapper::Inflector.underscore(field).to_sym }
        struct = Struct.new(*fields)

        results = []

        while reader.next!
          results << struct.new(*reader.values)
        end

        results
      end

      # @api private
      def select_field(reader)
        results = []

        while reader.next!
          results << reader.values.at(0)
        end

        results
      end

      # This module is just for organization. The methods are included into the
      # Adapter below.
      module SQL #:nodoc:
        IDENTIFIER_MAX_LENGTH = 128

        # @api semipublic
        def property_to_column_name(property, qualify)
          column_name = ''

          case qualify
            when true
              column_name << "#{quote_name(property.model.storage_name(name))}."
            when String
              column_name << "#{quote_name(qualify)}."
          end

          column_name << quote_name(property.field)
        end

        attr_accessor :path_aliases

        private

        # Adapters requiring a RETURNING syntax for INSERT statements
        # should overwrite this to return true.
        #
        # @api private
        def supports_returning?
          false
        end

        # Adapters that do not support the DEFAULT VALUES syntax for
        # INSERT statements should overwrite this to return false.
        #
        # @api private
        def supports_default_values?
          true
        end

        # TODO: nuke -- here just for debugging.
        # Examples: to_fullpath([hop]), to_fullpath(hops), to_fullpath(query.links[0])
        def to_fullpath(links)
          links.map { |l| ["#{l.target_model.storage_name(name)}<->#{l.source_model.storage_name(name)}"] }.flatten
          #links.map { |l| ["#{l.field.underscore}<->#{l.inverse.field.underscore}"] }.flatten
        end

        # Given as paths:
        # [
        #  ["accounting_ledgers<->user", "user<->accounts"],
        #  ["accounting_ledgers<->user", "user<->user_programs"],
        #  ["accounting_ledgers<->program"],
        # ]
        #
        # Produce:
        # {
        #   ["accounting_ledgers<->user"]                         => 'user_1',
        #   ["accounting_ledgers<->user", "user<->accounts"]      => 'accounts_1',
        #   ["accounting_ledgers<->user", "user<->user_programs"] => "user_programs_1"
        #   ["accounting_ledgers<->program"]                      => 'program_1'
        # }
        #
        # paths = list of all link chains; maps to: Ooga.all('foo.bar.blort' => true, 'balls' => 1)
        # path  = full link chain; maps to: 'foo.bar.blort' => true
        # hops  = 1->full links (cumulative); maps to: ['foo.bar'], ['foo.bar', 'bar.blort']
        # hop   = a single link (individual); maps to: ['foo.bar']
        #
        # - each hop represents a join and thus something that must be aliased
        # - inside a path, all hops are unique, thus all deserve their own aliases
        # - across all paths, links are not unique (because they occur within different
        #   paths), thus they should bump the alias count if they collide
        def generate_path_aliases(paths)
          path_aliases = {}
          alias_depths = Hash.new(0)

          paths.each do |path|
            hops = []

            path.each do |hop|
              hops << hop

              path_aliases[hops.hash] ||= begin
                alias_target                = hop.source_model.storage_name(name)
                alias_depths[alias_target] += 1

                "#{alias_target}_#{alias_depths[alias_target]}"
              end
            end
          end

          return path_aliases
        end

        # Constructs SELECT statement for given query,
        #
        # @return [String] SELECT statement as a string
        #
        # @api private
        def select_statement(query)
          qualify  = query.links.any?
          fields   = query.fields
          order_by = query.order
          group_by = if query.unique?
            fields.select { |property| property.kind_of?(Property) }
          end

          # [jpr5] Approach:
          #  - generate aliases for any links
          #  - walk link groups to build joins
          #    - the alias list is also the join list, but is now a flat list (what links was before)
          #  - walk the conditions list to build the condition statement
          #    - the comparisons that have .links will use path_aliases as their src table
          #    - everything else uses source_model's storage_name(name)
          #    - just need to override qualify with a string when comparison.links is present

          self.path_aliases = generate_path_aliases(query.links)

          conditions, bind_values = conditions_statement(query.conditions, qualify)
          joins                   = join_statement(query, bind_values, qualify)

          statement = "SELECT #{columns_statement(fields, qualify)}"
          statement << " FROM #{quote_name(query.model.storage_name(name))}"
          statement << " #{joins}"                                         if qualify
          statement << " WHERE #{conditions}"                              unless conditions.blank?
          statement << " GROUP BY #{columns_statement(group_by, qualify)}" if group_by && group_by.any?
          statement << " ORDER BY #{order_statement(order_by, qualify)}"   if order_by && order_by.any?

          add_limit_offset!(statement, query.limit, query.offset, bind_values)

          return statement, bind_values
        end

        # default construction of LIMIT and OFFSET
        # overriden by some adapters (currently Oracle and SQL Server)
        def add_limit_offset!(statement, limit, offset, bind_values)
          if limit
            statement   << ' LIMIT ?'
            bind_values << limit
          end

          if limit && offset > 0
            statement   << ' OFFSET ?'
            bind_values << offset
          end
        end

        # Constructs INSERT statement for given query,
        #
        # @return [String] INSERT statement as a string
        #
        # @api private
        def insert_statement(model, properties, serial)
          statement = "INSERT INTO #{quote_name(model.storage_name(name))} "

          if supports_default_values? && properties.empty?
            statement << default_values_clause
          else
            statement << <<-SQL.compress_lines
              (#{properties.map { |property| quote_name(property.field) }.join(', ')})
              VALUES
              (#{(['?'] * properties.size).join(', ')})
            SQL
          end

          if supports_returning? && serial
            statement << returning_clause(serial)
          end

          statement
        end

        # by default PostgreSQL syntax
        # overrided in Oracle adapter
        def default_values_clause
          'DEFAULT VALUES'
        end

        # by default PostgreSQL syntax
        # overrided in Oracle adapter
        def returning_clause(serial)
          " RETURNING #{quote_name(serial.field)}"
        end

        # Constructs UPDATE statement for given query,
        #
        # @return [String] UPDATE statement as a string
        #
        # @api private
        def update_statement(properties, query)
          model = query.model
          name  = self.name

          # TODO: DRY this up with delete_statement
          conditions_statement, bind_values = if query.limit || query.links.any?
            subquery(query, model.key(name), false)
          else
            conditions_statement(query.conditions)
          end

          statement = "UPDATE #{quote_name(model.storage_name(name))}"
          statement << " SET #{properties.map { |property| "#{quote_name(property.field)} = ?" }.join(', ')}"
          statement << " WHERE #{conditions_statement}" unless conditions_statement.blank?

          return statement, bind_values
        end

        # Constructs DELETE statement for given query,
        #
        # @return [String] DELETE statement as a string
        #
        # @api private
        def delete_statement(query)
          model = query.model
          name  = self.name

          # TODO: DRY this up with update_statement
          conditions_statement, bind_values = if query.limit || query.links.any?
            subquery(query, model.key(name), false)
          else
            conditions_statement(query.conditions)
          end

          statement = "DELETE FROM #{quote_name(model.storage_name(name))}"
          statement << " WHERE #{conditions_statement}" unless conditions_statement.blank?

          return statement, bind_values
        end

        # Constructs comma separated list of fields
        #
        # @return [String]
        #   list of fields as a string
        #
        # @api private
        def columns_statement(properties, qualify)
          properties.map { |property| property_to_column_name(property, qualify) }.join(', ')
        end

        # Constructs joins clause
        #
        # @return [String]
        #   joins clause
        #
        # @api private
        #
        # NOTE: New join_statement that uses path_aliases to construct properly-scoped
        # JOIN statements.
        def join_statement(query, bind_values, qualify)
          statements = []
          join_bind_values = []

          # Some links might be duplicates, so we note which paths we've visited so we
          # don't end up re-aliasing the same table connection (error).
          visited_hops = Set.new

          query.links.uniq.each do |path|
            target_alias = query.model.storage_name(name)

            hops = []
            path.each do |hop|
              hops << hop

              # [jpr5] knowtheory, this is where I think a problem lurks -- I think the
              # source_model isn't always inverted properly..  the issue is either here or
              # up in generate_path_aliases.
              source_alias = self.path_aliases[hops.hash]
              source_name  = hop.source_model.storage_name(name)

              # If we haven't already visited this path, accumulate a join
              #
              # TODO: verify that skipping over an existing relationship like this doesn't
              # F up the extra_join_conditions processing.  If Relationship#hash takes
              # into account any additional scope, then we're good.  Or maybe it doesn't
              # matter, since you can't have more than one Relationship of the same name
              # on the same model.
              hop_hash = hops.hash
              unless visited_hops.include?(hop_hash)
                visited_hops << hop_hash
                statements << "INNER JOIN #{quote_name(source_name)} #{quote_name(source_alias)} ON"
                statements << join_conditions(hop, target_alias, source_alias)
                statements << extra_join_conditions(hop, target_alias, join_bind_values)
              end

              target_alias = source_alias
            end
          end

          # prepend the join bind values to the statement bind values
          bind_values.unshift(*join_bind_values)

          return statements.join(' ')
        end

        def join_conditions(relationship, target_alias, source_alias)
          return relationship.target_key.zip(relationship.source_key).map do |target_property, source_property|
            "#{property_to_column_name(target_property, target_alias)} = #{property_to_column_name(source_property, source_alias)}"
          end.join(' AND ')
        end

        def extra_join_conditions(relationship, target_alias, bind_values)
          conditions = DataMapper.repository(name).scope do
            relationship.target_model.all(relationship.query).query.conditions
          end

          return '' if conditions.nil?

          # FIXME: [jpr5] wtf is this and how does it come to be?  I need concrete example
          # to test properly.  Though I don't think I broke it because I maintained how
          # the bind_values are generated by conditions_statement's first call up in
          # select_statement, and again in join_statement.
          extra_statement, extra_bind_values = conditions_statement(conditions, target_alias)
          bind_values += extra_bind_values
          return "AND #{extra_statement}"
        end

        # Constructs where clause
        #
        # @return [String]
        #   where clause
        #
        # @api private
        def conditions_statement(conditions, qualify = false)
          case conditions
            when Query::Conditions::NotOperation       then negate_operation(conditions.operand, qualify)
            when Query::Conditions::AbstractOperation  then operation_statement(conditions, qualify)
            when Query::Conditions::AbstractComparison then comparison_statement(conditions, qualify)
            when Array
              statement, bind_values = conditions  # handle raw conditions
              [ "(#{statement})", bind_values ].compact
          end
        end

        # @api private
        def supports_subquery?(*)
          true
        end

        # @api private
        def subquery(query, subject, qualify)
          source_key, target_key = subquery_keys(subject)

          if query.repository.name == name && supports_subquery?(query, source_key, target_key, qualify)
            subquery_statement(query, source_key, target_key, qualify)
          else
            subquery_execute(query, source_key, target_key, qualify)
          end
        end

        # @api private
        def subquery_statement(query, source_key, target_key, qualify)
          query = subquery_query(query, source_key)
          select_statement, bind_values = select_statement(query)

          statement = if target_key.size == 1
            property_to_column_name(target_key.first, qualify)
          else
            "(#{target_key.map { |property| property_to_column_name(property, qualify) }.join(', ')})"
          end

          statement << " IN (#{select_statement})"

          return statement, bind_values
        end

        # @api private
        def subquery_execute(query, source_key, target_key, qualify)
          query      = subquery_query(query, source_key)
          sources    = query.model.all(query)
          conditions = Query.target_conditions(sources, source_key, target_key)

          if conditions.valid?
            conditions_statement(conditions, qualify)
          else
            [ '1 = 0', [] ]
          end
        end

        # @api private
        def subquery_keys(subject)
          case subject
            when Associations::Relationship
              relationship = subject.inverse
              [ relationship.source_key, relationship.target_key ]
            when PropertySet
              [ subject, subject ]
          end
        end

        # @api private
        def subquery_query(query, source_key)
          # force unique to be false because PostgreSQL has a problem with
          # subselects that contain a GROUP BY with different columns
          # than the outer-most query
          query = query.merge(:fields => source_key, :unique => false)
          query.update(:order => nil) unless query.limit
          query
        end

        # Constructs order clause
        #
        # @return [String]
        #   order clause
        #
        # @api private
        def order_statement(order, qualify)
          statements = order.map do |direction|
            statement = property_to_column_name(direction.target, qualify)
            statement << ' DESC' if direction.operator == :desc
            statement
          end

          statements.join(', ')
        end

        # @api private
        def negate_operation(operand, qualify)
          statement, bind_values = conditions_statement(operand, qualify)
          statement = "NOT(#{statement})" unless statement.nil?
          [ statement, bind_values ]
        end

        # @api private
        def operation_statement(operation, qualify)
          statements  = []
          bind_values = []

          operation.each do |operand|
            statement, values = conditions_statement(operand, qualify)
            next unless statement
            statements << statement
            bind_values.concat(values) if values
          end

          statement = statements.join(" #{operation.slug.to_s.upcase} ")

          if statements.size > 1
            statement = "(#{statement})"
          end

          return statement, bind_values
        end

        # Constructs comparison clause
        #
        # @return [String]
        #   comparison clause
        #
        # @api private
        def comparison_statement(comparison, qualify)
          subject = comparison.subject
          value   = comparison.value

          # TODO: move exclusive Range handling into another method, and
          # update conditions_statement to use it

          # break exclusive Range queries up into two comparisons ANDed together
          if value.kind_of?(Range) && value.exclude_end?
            operation = Query::Conditions::Operation.new(:and,
              Query::Conditions::Comparison.new(:gte, subject, value.first),
              Query::Conditions::Comparison.new(:lt,  subject, value.last)
            )

            statement, bind_values = conditions_statement(operation, qualify)

            return "(#{statement})", bind_values
          elsif comparison.relationship?
            if value.respond_to?(:query) && value.respond_to?(:loaded?) && !value.loaded?
              return subquery(value.query, subject, qualify)
            else
              return conditions_statement(comparison.foreign_key_mapping, qualify)
            end
          elsif comparison.slug == :in && !value.any?
            return []  # match everything
          end

          # NOTE: This relies on the dm-core fix_joins work -- conditions (comparisons)
          # that have links references can just simply be looked up in our generated
          # path_aliases to find what table alias to use.  property_to_column_name()
          # catches when qualify is a string and just uses it as the table name instead
          # (seems like a hack someone made in a rush..).
          if path_alias = self.path_aliases[comparison.links.hash]
            qualify = path_alias
          end
          column_name = property_to_column_name(subject, qualify)
          operator    = comparison_operator(comparison)

          # if operator return value contains ? then it means that it is function call
          # and it contains placeholder (%s) for property name as well (used in Oracle adapter for regexp operator)
          if operator.include?('?')
            return operator % column_name, [ value ]
          else
            return "#{column_name} #{operator} #{value.nil? ? 'NULL' : '?'}", [ value ].compact
          end
        end

        def comparison_operator(comparison)
          subject = comparison.subject
          value   = comparison.value

          case comparison.slug
            when :eql    then equality_operator(subject, value)
            when :in     then include_operator(subject, value)
            when :regexp then regexp_operator(value)
            when :like   then like_operator(value)
            when :gt     then '>'
            when :lt     then '<'
            when :gte    then '>='
            when :lte    then '<='
          end
        end

        # @api private
        def equality_operator(property, operand)
          operand.nil? ? 'IS' : '='
        end

        # @api private
        def include_operator(property, operand)
          case operand
            when Array then 'IN'
            when Range then 'BETWEEN'
          end
        end

        # @api private
        def regexp_operator(operand)
          '~'
        end

        # @api private
        def like_operator(operand)
          'LIKE'
        end

        # @api private
        def quote_name(name)
          "\"#{name[0, self.class::IDENTIFIER_MAX_LENGTH].gsub('"', '""')}\""
        end

      end

      include SQL

    end

    const_added(:DataObjectsAdapter)
  end
end
