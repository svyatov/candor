# frozen_string_literal: true

require "test_helper"
require "rbs"

# `rake rbs` runs `rbs validate`, which checks that `sig/` parses and resolves. It never reads `lib/`, so
# a renamed method or a deleted constant leaves a signature that still validates and now lies.
#
# The types themselves stay verified by review — see CONTRIBUTING.md for why neither `RBS::Test` nor
# Steep is wired up. The *names* do not need a type checker: `sig/` declares the public API, exactly, and
# both directions of that claim are cheap to assert against the loaded gem.
class SigTest < CandorTest
  ENVIRONMENT = begin
    loader = RBS::EnvironmentLoader.new(core_root: nil)
    loader.add(path: Pathname("sig"))
    RBS::Environment.from_loader(loader).resolve_type_names
  end

  # A nested class is its own declaration, not a constant of its parent.
  DECLARED_TYPES = ENVIRONMENT.class_decls.keys.map(&:to_s).freeze

  def test_every_name_the_signatures_declare_exists
    each_declaration do |mod, declared|
      declared[:constants].each do |name|
        assert mod.const_defined?(name, false), "sig/ declares #{mod}::#{name}, which does not exist"
      end
      declared[:instance].each do |name|
        assert defined_instance?(mod, name), "sig/ declares #{mod}##{name}, which does not exist"
      end
      declared[:singleton].each do |name|
        assert_respond_to mod, name, "sig/ declares #{mod}.#{name}, which does not exist"
      end
    end
  end

  # The reverse: nothing public may go undeclared. `constants(false)` omits `private_constant` entries and
  # `instance_methods(false)` omits `initialize`, so the private surface is out of scope by construction —
  # which is the invariant, not a gap in it.
  def test_every_public_name_the_gem_defines_is_declared
    each_declaration do |mod, declared|
      constants = mod.constants(false).reject { |name| DECLARED_TYPES.include?("::#{mod}::#{name}") }

      assert_empty constants - declared[:constants], "#{mod} has public constants missing from sig/"
      assert_empty mod.instance_methods(false) - declared[:instance], "#{mod} has public methods missing from sig/"
      assert_empty mod.singleton_methods(false) - declared[:singleton], "#{mod} has class methods missing from sig/"
    end
  end

  private

  # @yield [Module, Hash{Symbol => Array<Symbol>}] each declared type and the names its signature gives it
  def each_declaration
    refute_empty ENVIRONMENT.class_decls, "no signatures were loaded from sig/"

    ENVIRONMENT.class_decls.each do |type_name, entry|
      yield constant(type_name), declared(entry)
    end
  end

  # `const_get` reaches a `private_constant`; the `::` a signature is written with would not.
  #
  # @param type_name [RBS::TypeName]
  # @return [Module]
  def constant(type_name)
    type_name.to_s.delete_prefix("::").split("::").reduce(Object) { |mod, name| mod.const_get(name, false) }
  end

  # @param entry [RBS::Environment::ClassEntry, RBS::Environment::ModuleEntry]
  # @return [Hash{Symbol => Array<Symbol>}]
  def declared(entry)
    names = { constants: [], instance: [], singleton: [] }
    entry.each_decl do |decl|
      decl.members.each do |member|
        case member
        when RBS::AST::Declarations::Constant then names[:constants] << member.name.name
        when RBS::AST::Members::MethodDefinition then names[member.kind] << member.name
        end
      end
    end
    names
  end

  # A signature does not say whether a method is public, and `initialize` is always private.
  #
  # @return [Boolean]
  def defined_instance?(mod, name) = mod.method_defined?(name) || mod.private_method_defined?(name)
end
