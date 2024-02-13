class SynchronizedAttributeHandler < YARD::Handlers::Ruby::AttributeHandler
  handles method_call(:attr_inclusive_reader)
  handles method_call(:attr_exclusive_writer)
  handles method_call(:attr_synchronized_accessor)
  namespace_only

  process do
    return if statement.type == :var_ref || statement.type == :vcall

    read = true
    write = false
    params = statement.parameters(false).dup

    # Change read/write based on attr_reader/writer/accessor
    case statement.method_name(true)
    when :attr
      # In the case of 'attr', the second parameter (if given) isn't a symbol.
      if params.size == 2 && (params.pop == s(:var_ref, s(:kw, 'true')))
        write = true
      end
    when :attr_synchronized_accessor
      write = true
    when :attr_inclusive_reader
      # change nothing
    when :attr_exclusive_writer
      read = false
      write = true
    end

    # Add all attributes
    validated_attribute_names(params).each do |name|
      namespace.attributes[scope][name] ||= SymbolHash[read: nil, write: nil]

      # Show their methods as well
      { read: name, write: "#{name}=" }.each do |type, meth|
        if type == :read ? read : write
          o = MethodObject.new(namespace, meth, scope)
          if type == :write
            o.parameters = [['value', nil]]
            src = "def #{meth}(value)"
            full_src = "#{src}\n  @#{name} = value\nend"
            doc = "Sets the attribute #{name}\n@param value the value to set the attribute #{name} to."
          else
            src = "def #{meth}"
            full_src = "#{src}\n  @#{name}\nend"
            doc = "Returns the value of attribute #{name}"
          end
          o.source ||= full_src
          o.signature ||= src
          register(o)
          o.docstring = doc if o.docstring.blank?(false)

          # Regsiter the object explicitly
          namespace.attributes[scope][name][type] = o
        else
          obj = namespace.children.find { |other| other.name == meth.to_sym && other.scope == scope }

          # register an existing method as attribute
          namespace.attributes[scope][name][type] = obj if obj
        end
      end
    end
  end
end
