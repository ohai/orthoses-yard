module Orthoses
  class YARD
    class YARD2RBS
      class << self
        def run(yardoc:, &block)
          new(yardoc: yardoc, block: block).run
        end
      end

      # @return [YARD::CodeObjects::t]
      attr_reader :yardoc

      # @return [Proc]
      attr_reader :block

      # @return [RBS::Types::Bases::Any]
      attr_reader :untyped

      # @return [RBS::Types::Bases::Void]
      attr_reader :void

      # @return [RBS::Types::Bases::Bool]
      attr_reader :bool

      def initialize(yardoc:, block:)
        @yardoc = yardoc
        @block = block

        # statics
        @untyped = ::RBS::Types::Bases::Any.new(location: nil)
        @void = ::RBS::Types::Bases::Void.new(location: nil)
        @bool = ::RBS::Types::Bases::Bool.new(location: nil)
      end

      # @return [void]
      def run
        Orthoses.logger.info("YARD will generate about #{yardoc.inspect}")
        block.call(yardoc.path, yardoc.docstring.all, nil)
        yardoc.children.each do |child|
          case child.type
          when :module, :class
            self.class.new(yardoc: child, block: block).run
          end
        end
        generate_for_attributes
        generate_for_methods
        generate_for_constants
        generate_for_classvariable
      end

      # @return [void]
      def generate_for_attributes
        yardoc.attributes.each do |kind, attributes|
          prefix = kind == :class ? 'self.' : ''
          attributes.each do |name, class_attributes|
            if class_attributes[:read] && class_attributes[:write]
              visibility = class_attributes[:read].visibility == :private ? 'private ' : ''
              type = tag_types_to_rbs_type(class_attributes[:read].tags('return').flat_map(&:types))
              block.call(yardoc.path, class_attributes[:read].docstring.all, "#{visibility}attr_accessor #{prefix}#{name}: #{type}")
            elsif class_attributes[:read]
              visibility = class_attributes[:read].visibility == :private ? 'private ' : ''
              type = tag_types_to_rbs_type(class_attributes[:read].tags('return').flat_map(&:types))
              block.call(yardoc.path, class_attributes[:read].docstring.all, "#{visibility}attr_reader #{prefix}#{name}: #{type}")
            elsif class_attributes[:write]
              visibility = class_attributes[:write].visibility == :private ? 'private ' : ''
              type = tag_types_to_rbs_type(class_attributes[:write].tags('return').flat_map(&:types))
              block.call(yardoc.path, class_attributes[:write].docstring.all, "#{visibility}attr_writer #{prefix}#{name}: #{type}")
            else
              raise "bug"
            end
          end
        end
      end

      # @return [void]
      def generate_for_methods
        return if yardoc.to_s.empty?

        yardoc.meths(inherited: false).each do |meth|
          # skip attribute methods because of generate_for_attributes
          next if meth.attr_info

          # skip no tags methods
          next if meth.tags.empty?

          namespace = meth.namespace
          method_name = meth.name

          begin
            mod = Object.const_get(namespace.to_s)
            case meth.scope
            when :class
              prefix = 'self.'
              method_object = mod.method(method_name)
            when :instance
              prefix = ''
              method_object = mod.instance_method(method_name)
            else
              raise "bug"
            end
          rescue NameError
            Orthoses.logger.warn("[YARD] skip #{meth.inspect} because cannot get method object")
            next
          end

          if meth.is_alias?
            orig_key = yardoc.aliases[meth]
            block.call(yardoc.to_s, "", "alias #{prefix}#{meth.name} #{prefix}#{orig_key}")
            next
          end

          required_positionals = []
          optional_positionals = []
          rest_positionals = nil
          trailing_positionals = []
          required_keywords = {}
          optional_keywords = {}
          rest_keywords = nil

          requireds = required_positionals

          # @type var method_object: (Method | UnboundMethod)
          method_object.parameters.each do |kind, name|
            type = meth.tags("param")
              .find { |tag| tag.name == name.to_s }
              &.then { |tag| tag_types_to_rbs_type(tag.types) } || untyped

            case kind
            when :req
              requireds << ::RBS::Types::Function::Param.new(name: name, type: type)
            when :opt
              requireds = trailing_positionals
              optional_positionals << ::RBS::Types::Function::Param.new(name: name, type: type)
            when :rest
              requireds = trailing_positionals
              name = nil if name == :*
              rest_positionals = ::RBS::Types::Function::Param.new(name: name, type: type)
            when :keyreq
              required_keywords[name] = ::RBS::Types::Function::Param.new(name: nil, type: type)
            when :key
              optional_keywords[name] = ::RBS::Types::Function::Param.new(name: nil, type: type)
            when :keyrest
              rest_keywords = ::RBS::Types::Function::Param.new(name: name, type: type)
            when :block
              # block parameters cannot get by method object
            else
              raise "bug"
            end
          end

          return_type =
            if method_object.name == :initialize
              void
            else
              tag_types_to_rbs_type(meth.tags("return").flat_map(&:types))
            end

          function = ::RBS::Types::Function.new(
            required_positionals: required_positionals,
            optional_positionals: optional_positionals,
            rest_positionals: rest_positionals,
            trailing_positionals: trailing_positionals,
            required_keywords: required_keywords,
            optional_keywords: optional_keywords,
            rest_keywords: rest_keywords,
            return_type: return_type,
          )

          yield_type =
            if !meth.tags("yieldparam").empty? || !meth.tags("yieldreturn").empty?
              block_required_positionals = meth.tags("yieldparam").map do |tag|
                ::RBS::Types::Function::Param.new(
                  name: tag.name,
                  type: tag_types_to_rbs_type(tag.types) || untyped
                )
              end
              block_return_type = tag_types_to_rbs_type(meth.tags("yieldreturn").flat_map(&:types)) || untyped
              ::RBS::Types::Block.new(
                required: true,
                type: ::RBS::Types::Function.new(
                  required_positionals: block_required_positionals,
                  optional_positionals: [],
                  rest_positionals: nil,
                  trailing_positionals: [],
                  required_keywords: {},
                  optional_keywords: {},
                  rest_keywords: nil,
                  return_type: block_return_type,
                ),
              )
            else
              nil
            end

          method_type = ::RBS::MethodType.new(
            location: nil,
            type_params: [],
            type: function,
            block: yield_type
          )

          visibility = meth.visibility == :private ? 'private ' : ''
          block.call(yardoc.to_s, meth.docstring.all, "#{visibility}def #{prefix}#{method_name}: #{method_type}")
        end
      end

      # @return [void]
      def generate_for_constants
        yardoc.constants(inherited: false).each do |const|
          return_tags = const.tags('return')
          return_type = return_tags.empty? ? untyped : tag_types_to_rbs_type(return_tags.flat_map(&:types))
          block.call(const.namespace.to_s, const.docstring.all, "#{const.name}: #{return_type}")
        end
      end

      # @return [void]
      def generate_for_classvariable
        yardoc.cvars.each do |cvar|
          return_tags = cvar.tags('return')
          return_type = return_tags.empty? ? untyped : tag_types_to_rbs_type(return_tags.flat_map(&:types))
          block.call(cvar.namespace.to_s, cvar.docstring.all, "#{cvar.name}: #{return_type}")
        end
      end

      # @return [RBS::Types::t]
      def tag_types_to_rbs_type(tag_types)
        return untyped if tag_types.nil?
        return untyped if tag_types.empty?

        begin
          types_explainers = ::YARD::Tags::TypesExplainer::Parser.parse(tag_types.uniq.join(", "))
        rescue SyntaxError
          Orthoses.logger.warn("#{tag_types} in #{yardoc.inspect} cannot parse as tags. use untyped instead")
          return untyped
        end

        wrap(recursive_resolve(types_explainers)).tap do |rbs|
          Orthoses.logger.debug("#{yardoc.inspect} tag #{tag_types} => #{rbs}")
        end
      end

      # @return [RBS::Types::t]
      def wrap(types)
        if types.nil? || types.empty? || types == [untyped]
          return untyped
        end

        if 1 < types.length
          if index = types.find_index { |t| t.to_s == "nil" }
            types.delete_at(index)
            is_optional = true
            if types == [untyped]
              return untyped
            end
          end
        end
        is_union = 1 < types.length

        if is_union
          if is_optional
            ::RBS::Types::Optional.new(
              type: ::RBS::Types::Union.new(
                types: types,
                location: nil,
              ),
              location: nil,
            )
          else
            ::RBS::Types::Union.new(
              types: types,
              location: nil,
            )
          end
        elsif is_optional
          ::RBS::Types::Optional.new(
            type: types.first,
            location: nil,
          )
        else
          types.first
        end
      end

      # @return [Array<RBS::Types::t>]
      def recursive_resolve(types_explainer_types)
        types_explainer_types.map do |types_explainer_type|
          case types_explainer_type
          when ::YARD::Tags::TypesExplainer::FixedCollectionType
            ::RBS::Types::Tuple.new(
              types: recursive_resolve(types_explainer_type.types),
              location: nil
            )
          when ::YARD::Tags::TypesExplainer::CollectionType
            type = wrap(recursive_resolve(types_explainer_type.types))
            if types_explainer_type.name == "Class"
              if type.to_s == "untyped"
                untyped
              else
                ::RBS::Types::ClassSingleton.new(
                  name: type,
                  location: nil
                )
              end
            else
              ::RBS::Types::ClassInstance.new(
                name: TypeName(types_explainer_type.name),
                args: [type],
                location: nil
              )
            end
          when ::YARD::Tags::TypesExplainer::HashCollectionType
            ::RBS::Types::ClassInstance.new(
              name: TypeName(types_explainer_type.name),
              args: [
                wrap(recursive_resolve(types_explainer_type.key_types)),
                wrap(recursive_resolve(types_explainer_type.value_types)),
              ],
              location: nil
            )
          when ::YARD::Tags::TypesExplainer::Type
            if types_explainer_type.name.start_with?('#')
              Orthoses.logger.debug("interface for #{types_explainer_type.name} in #{yardoc.namespace} set `untyped` because it not implemented yet")
              untyped
              # interface
              # case types_explainer_type.name
              # when '#to_s'
              #   ::RBS::Types::Interface.new(
              #     name: '_ToS',
              #     args: [],
              #     location: nil
              #   )
              # else
              #   interface_method = types_explainer_type.name[1..-1]
              #   if interface_method.end_with?('=')
              #     interface_name = "_#{interface_method[0..-2].split('_').map(&:capitalize).join}Eq"
              #     @store[interface_name] << "def #{interface_method}: (untyped) -> untyped"
              #   else
              #     interface_name = "_#{interface_method.split('_').map(&:capitalize).join}"
              #     @store[interface_name] << "def #{interface_method}: () -> untyped"
              #   end

              #   ::RBS::Types::Interface.new(
              #     name: interface_name,
              #     args: [],
              #     location: nil
              #   )
              # end
            else
              case types_explainer_type.name
              when "Object" then next untyped
              when "Boolean" then next bool
              end

              begin
                rbs_type = ::RBS::Parser.parse_type(types_explainer_type.name)
                case rbs_type
                when ::RBS::Types::Bases::Base, ::RBS::Types::Literal
                  next rbs_type
                when ::RBS::Types::Alias
                end
              rescue ::RBS::ParsingError
              end

              if Utils.rbs_defined_class?(types_explainer_type.name, collection: true)
                ::RBS::Types::ClassInstance.new(
                  name: TypeName(types_explainer_type.name),
                  args: temporary_type_params(types_explainer_type.name),
                  location: nil
                )
              else
                name =
                  case types_explainer_type.name
                  when "Fixnum"
                    "Integer"
                  else
                    resolved = ::YARD::Registry.resolve(yardoc.namespace, types_explainer_type.name, true, false)
                    if resolved
                      resolved.to_s
                    else
                      Orthoses.logger.warn("#{types_explainer_type.name} in #{yardoc.namespace} set `untyped` because it cannot resolved type")
                      next untyped
                    end
                  end

                ::RBS::Types::ClassInstance.new(
                  name: TypeName(name),
                  args: [],
                  location: nil
                )
              end
            end
          else
            raise "bug"
          end
        end
      end

      # @return [Array<RBS::Types::Bases::Any>]
      def temporary_type_params(name)
        params = Utils.known_type_params(name)
        return [] unless params
        params.map { untyped }
      end
    end
  end
end
