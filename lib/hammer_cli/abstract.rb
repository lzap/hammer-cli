require 'hammer_cli/exception_handler'
require 'hammer_cli/logger_watch'
require 'hammer_cli/options/option_definition'
require 'clamp'
require 'logging'

module HammerCLI

  class CommandConflict < StandardError; end

  class AbstractCommand < Clamp::Command

    class << self
      attr_accessor :validation_block
    end

    def adapter
      :base
    end

    def run(arguments)
      exit_code = super
      raise "exit code must be integer" unless exit_code.is_a? Integer
      return exit_code
    rescue => e
      handle_exception e
    end

    def parse(arguments)
      super
      validate_options
      safe_options = options.dup
      safe_options.keys.each { |k| safe_options[k] = '***' if k.end_with?('password') }
      logger.info "Called with options: %s" % safe_options.inspect
    rescue HammerCLI::Validator::ValidationError => e
      signal_usage_error e.message
    end

    def execute
      HammerCLI::EX_OK
    end

    def self.validate_options(&block)
      self.validation_block = block
    end

    def validate_options
      validator.run &self.class.validation_block if self.class.validation_block
    end

    def exception_handler
      @exception_handler ||= exception_handler_class.new(:output => output)
    end

    def initialize(*args)
      super
      context[:path] ||= []
      context[:path] << self
    end

    def parent_command
      context[:path][-2]
    end

    def self.remove_subcommand(name)
      self.recognised_subcommands.delete_if do |sc|
        if sc.is_called?(name)
          logger.info "subcommand #{name} (#{sc.subcommand_class}) was removed."
          true
        else
          false
        end
      end
    end

    def self.subcommand!(name, description, subcommand_class = self, &block)
      remove_subcommand(name)
      self.subcommand(name, description, subcommand_class, &block)
      logger.info "subcommand #{name} (#{subcommand_class}) was created."
    end

    def self.subcommand(name, description, subcommand_class = self, &block)
      existing = find_subcommand(name)
      if existing
        raise HammerCLI::CommandConflict, "can't replace subcommand #{name} (#{existing.subcommand_class}) with #{name} (#{subcommand_class})"
      end
      super
    end

    def self.output(definition=nil, &block)
      dsl = HammerCLI::Output::Dsl.new
      dsl.build &block if block_given?
      output_definition.append definition.fields unless definition.nil?
      output_definition.append dsl.fields
    end

    def output
      @output ||= HammerCLI::Output::Output.new(context, :default_adapter => adapter)
    end

    def output_definition
      self.class.output_definition
    end

    def self.inherited_output_definition
      od = nil
      if superclass.respond_to? :output_definition
        od_super = superclass.output_definition
        od = od_super.dup unless od_super.nil?
      end
      od
    end

    def self.output_definition
      @output_definition = @output_definition || inherited_output_definition || HammerCLI::Output::Definition.new
      @output_definition
    end

    protected

    def interactive?
      HammerCLI.interactive?
    end


    def print_record(definition, record)
      output.print_record(definition, record)
    end

    def print_collection(definition, collection)
      output.print_collection(definition, collection)
    end

    def print_message(msg, msg_params={})
      output.print_message(msg, msg_params)
    end

    def self.logger(name=self)
      logger = Logging.logger[name]
      logger.extend(HammerCLI::Logger::Watch) if not logger.respond_to? :watch
      logger
    end

    def logger(name=self.class)
      self.class.logger(name)
    end

    def validator
      options = self.class.recognised_options.collect{|opt| opt.of(self)}
      @validator ||= HammerCLI::Validator.new(options)
    end

    def handle_exception(e)
      exception_handler.handle_exception(e)
    end

    def exception_handler_class
      #search for exception handler class in parent modules/classes
      module_list = self.class.name.to_s.split('::').inject([Object]) do |mod, class_name|
        mod << mod[-1].const_get(class_name)
      end
      module_list.reverse.each do |mod|
        return mod.send(:exception_handler_class) if mod.respond_to? :exception_handler_class
      end
      return HammerCLI::ExceptionHandler
    end

    def self.desc(desc=nil)
      @desc = desc if desc
      @desc
    end

    def self.command_name(name=nil)
      @name = name if name
      @name || (superclass.respond_to?(:command_name) ? superclass.command_name : nil)
    end

    def self.autoload_subcommands
      commands = constants.map { |c| const_get(c) }.select { |c| c <= HammerCLI::AbstractCommand }
      commands.each do |cls|
        subcommand cls.command_name, cls.desc, cls
      end
    end

    def self.define_simple_writer_for(attribute, &block)
      define_method(attribute.write_method) do |value|
        value = instance_exec(value, &block) if block
        if attribute.respond_to?(:context_target) && attribute.context_target
          context[attribute.context_target] = value
        end
        attribute.of(self).set(value)
      end
    end

    def self.option(switches, type, description, opts = {}, &block)
      formatter = opts.delete(:format)
      context_target = opts.delete(:context_target)

      HammerCLI::Options::OptionDefinition.new(switches, type, description, opts).tap do |option|
        declared_options << option

        option.value_formatter = formatter
        option.context_target = context_target
        block ||= option.default_conversion_block

        define_accessors_for(option, &block)
      end
    end

    def all_options
      self.class.recognised_options.inject({}) do |h, opt|
        h[opt.attribute_name] = send(opt.read_method)
        h
      end
    end

    def options
      all_options.reject {|key, value| value.nil? }
    end
  end
end
