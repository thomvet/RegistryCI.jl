import Pkg
import GitCommand
import Test

function gather_stdlib_uuids()
    if VERSION < v"1.1"
        return Set{Base.UUID}(x for x in keys(Pkg.Types.gather_stdlib_uuids()))
    else
        return Set{Base.UUID}(x for x in keys(Pkg.Types.stdlib()))
    end
end

# For when you have a registry that has packages with dependencies obtained from
# another dependency registry. For example, packages registered at the BioJuliaRegistry
# that have General dependencies. BJW.
function load_registry_dep_uuids(registry_deps_urls::Vector{<:AbstractString} = String[])
    temp_depot = mktempdir() # make a temp depot
    atexit(() -> rm(temp_depot; force = true, recursive = true))
    original_depot_path = deepcopy(Base.DEPOT_PATH)
    empty!(Base.DEPOT_PATH)
    push!(Base.DEPOT_PATH, temp_depot) # use the temp depot
    # Get the registries!
    for url in registry_deps_urls
        Pkg.Registry.add(Pkg.RegistrySpec(url = url))
    end
    # Now use the RegistrySpec's to find the Project.toml's. I know
    # .julia/registires/XYZ/ABC is the most likely place, but this way the
    # function never has to assume. BJW.
    extrauuids = Set{Base.UUID}()
    for spec in Pkg.Types.collect_registries()
        if spec.url ∈ registry_deps_urls
            reg = Pkg.TOML.parsefile(joinpath(spec.path, "/Registry.toml"))
            for x in keys(reg["packages"])
                push!(extrauuids, Base.UUID(x))
            end
        end
    end
    empty!(Base.DEPOT_PATH)
    for x in original_depot_path
        push!(Base.DEPOT_PATH, x) # restore the original DEPOT_PATH
    end
    rm(temp_depot; force = true, recursive = true)
    return extrauuids
end

#########################
# Testing of registries #
#########################

"""
    test(path)

Run various checks on the registry located at `path`.
Checks for example that all files are parsable and
understandable by Pkg and consistency between Registry.toml
and each Package.toml.

If your registry has packages that have dependencies that are registered in other
registries elsewhere, then you may provide the github urls for those registries
using the `registry_deps` parameter.
"""
function test(path = pwd();
              registry_deps::Vector{<:AbstractString} = String[])
    Test.@testset "(Registry|Package|Versions|Deps|Compat).toml" begin; cd(path) do
        reg = Pkg.TOML.parsefile("Registry.toml")
        reguuids = Set{Base.UUID}(Base.UUID(x) for x in keys(reg["packages"]))
        stdlibuuids = gather_stdlib_uuids()
        registry_dep_uuids = load_registry_dep_uuids(registry_deps)
        alluuids = reguuids ∪ stdlibuuids ∪ registry_dep_uuids

        # Test that each entry in Registry.toml has a corresponding Package.toml
        # at the expected path with the correct uuid and name
        for (uuid, data) in reg["packages"]
            # Package.toml testing
            pkg = Pkg.TOML.parsefile(abspath(data["path"], "Package.toml"))
            Test.@test Base.UUID(uuid) == Base.UUID(pkg["uuid"])
            Test.@test data["name"] == pkg["name"]
            Test.@test Base.isidentifier(data["name"])
            Test.@test haskey(pkg, "repo")

            # Versions.toml testing
            vers = Pkg.TOML.parsefile(abspath(data["path"], "Versions.toml"))
            for (v, data) in vers
                Test.@test VersionNumber(v) isa VersionNumber
                Test.@test haskey(data, "git-tree-sha1")
            end

            # Deps.toml testing
            depsfile = abspath(data["path"], "Deps.toml")
            if isfile(depsfile)
                deps = Pkg.TOML.parsefile(depsfile)
                # Require all deps to exist in the General registry or be a stdlib
                depuuids = Set{Base.UUID}(Base.UUID(x) for (_, d) in deps for (_, x) in d)
                Test.@test depuuids ⊆ alluuids
                # Test that the way Pkg loads this data works
                Test.@test Pkg.Operations.load_package_data_raw(Base.UUID, depsfile) isa
                    Dict{Pkg.Types.VersionRange,Dict{String,Base.UUID}}
            end

            # Compat.toml testing
            compatfile = abspath(data["path"], "Compat.toml")
            if isfile(compatfile)
                compat = Pkg.TOML.parsefile(compatfile)
                # Test that all names with compat is a dependency
                compatnames = Set{String}(x for (_, d) in compat for (x, _) in d)
                if !(isempty(compatnames) || (length(compatnames)== 1 && "julia" in compatnames))
                    depnames = Set{String}(x for (_, d) in Pkg.TOML.parsefile(depsfile) for (x, _) in d)
                    push!(depnames, "julia") # All packages has an implicit dependency on julia
                    @assert compatnames ⊆ depnames
                end
                # Test that the way Pkg loads this data works
                Test.@test Pkg.Operations.load_package_data_raw(Pkg.Types.VersionSpec, compatfile) isa
                    Dict{Pkg.Types.VersionRange,Dict{String,Pkg.Types.VersionSpec}}
            end
        end
    end end
    return
end
