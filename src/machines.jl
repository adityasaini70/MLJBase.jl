## MACHINE TYPE

struct NotTrainedError{M} <: Exception
    mach::M
    operation::Symbol
end

Base.showerror(io::IO, e::NotTrainedError) =
    print(io, "$(e.mach) has not been trained. "*
          "Call `fit!` on the machine, or, "*
          "if you meant to create a "*
          "learning network `Node`, "*
          "use the syntax `node($(e.operation), mach::Machine)`. ")

caches_data_by_default(::Type{<:Model}) = true
caches_data_by_default(m::M) where M<:Model = caches_data_by_default(M)

mutable struct Machine{M<:Model,C} <: MLJType

    model::M
    old_model::M # for remembering the model used in last call to `fit!`
    fitresult
    cache

    # training arguments (`Node`s or user-specified data wrapped in
    # `Source`s):
    args::Tuple{Vararg{AbstractNode}}

    # cached model-specific reformatting of args (for C=true):
    data

    # cached subsample of data (for C=true):
    resampled_data

    report
    frozen::Bool
    old_rows
    state::Int
    old_upstream_state

    # cleared by fit!(::Node) calls; put! by `fit_only!(machine, true)` calls:
    fit_okay::Channel{Bool}

    function Machine(model::M, args::AbstractNode...;
                     cache=caches_data_by_default(M)) where M<:Model
        mach = new{M,cache}(model)
        mach.frozen = false
        mach.state = 0
        mach.args = args
        mach.old_upstream_state = upstream(mach)
        mach.fit_okay = Channel{Bool}(1)
        return mach
    end

end

upstream(mach::Machine) = Tuple(m.state for m in ancestors(mach))

"""
    ancestors(mach::Machine; self=false)

All ancestors of `mach`, including `mach` if `self=true`.

"""
function ancestors(mach::Machine; self=false)
    ret = Machine[]
    self && push!(ret, mach)
    return vcat(ret, (machines(N) for N in mach.args)...) |> unique
end


## CONSTRUCTORS

# In these checks the args are abstract nodes but `full=true` only
# makes sense if they are actually source nodes.

err_supervised_nargs() = ArgumentError(
    "`Supervised` models should have at least two "*
    "training arguments. "*
    "Use  `machine(model, X, y; ...)` or "*
    "`machine(model, X, y, extras...; ...)`. ")

err_unsupervised_nargs() = ArgumentError(
    "`Unsupervised` models should have one "*
    "training argument, except `Static` models, which have none. "*
    "Use  `machine(model, X; ...)` (usual case) or "*
    "`machine(model; ...)` (static case). ")

warn_scitype(model::Supervised, X) =
    "The scitype of `X`, in `machine(model, X, ...)` "*
    "is incompatible with "*
    "`model=$model`:\nscitype(X) = $(elscitype(X))\n"*
    "input_scitype(model) = $(input_scitype(model))."

warn_generic_scitype_mismatch(S, F) =
    "The scitype of `args` in `machine(model, args...; kwargs)` "*
    "does not match the scitype "*
    "expected by model's `fit` method.\n"*
    "  provided: $S\n  expected by fit: $F"

warn_scitype(model::Supervised, X, y) =
    "The scitype of `y`, in `machine(model, X, y, ...)` "*
    "is incompatible with "*
    "`model=$model`:\nscitype(y) = "*
    "$(elscitype(y))\ntarget_scitype(model) "*
    "= $(target_scitype(model))."

warn_scitype(model::Unsupervised, X) =
    "The scitype of `X`, in `machine(model, X)` is "*
    "incompatible with `model=$model`:\nscitype(X) = $(elscitype(X))\n"*
    "input_scitype(model) = $(input_scitype(model))."

err_length_mismatch(model::Supervised) = DimensionMismatch(
    "Differing number of observations "*
    "in input and target. ")

check(model::Any, args...; kwargs...) =
    throw(ArgumentError("Expected a `Model` instance, got $model. "))

function check_supervised(model, full, args...)
    nowarns = true

    nargs = length(args)
    nargs > 1 || throw(err_supervised_nargs())

    full || return nowarns

    X, y = args[1:2]

    # checks on input type:
    input_scitype(model) <: Unknown ||
        elscitype(X) <: input_scitype(model) || begin
            @warn warn_scitype(model, X)
            nowarns=false
        end

    # checks on target type:
    target_scitype(model) <: Unknown ||
        elscitype(y) <: target_scitype(model) || begin
            @warn warn_scitype(model, X, y)
            nowarns=false
        end

    # checks on dimension matching:
    scitype(X) == CallableReturning{Nothing} || nrows(X()) == nrows(y()) ||
        throw(err_length_mismatch(model))

    return nowarns

end

function check_unsupervised(model, full, args...)
    nowarns = true

    nargs = length(args)
    nargs <= 1 || throw(err_unsupervised_nargs())

    if full && nargs == 1
        X = args[1]
        # check input scitype
        input_scitype(model) <: Unknown ||
            elscitype(X) <: input_scitype(model) || begin
                @warn warn_scitype(model, X)
                nowarns=false
            end
    end
    return nowarns
end

function check(model::Model, args...; full=false)
    nowarns = true

    F = fit_data_scitype(model)
    (F >: Unknown || F >: Tuple{Unknown} || F >: NTuple{<:Any,Unknown}) &&
        return true

    S = Tuple{elscitype.(args)...}
    if !(S <: F)
        @warn warn_generic_scitype_mismatch(S, F)
        nowarns = false
    end
end

function check(model::Union{Supervised, SupervisedAnnotator}, args... ; full = false)
    check_supervised(model, full, args...)
end

function check(model::Unsupervised, args...; full=false)
    check_unsupervised(model, full, args...)
end

function check(model::UnsupervisedAnnotator, args... ; full = false)
    if length(args) <= 1
        check_unsupervised(model, full, args...)
    else
        check_supervised(model, full, args...)
    end
end

"""
    machine(model, args...; cache=true)

Construct a `Machine` object binding a `model`, storing
hyper-parameters of some machine learning algorithm, to some data,
`args`. Calling `fit!` on a `Machine` object stores in the machine
object the outcomes of applying the algorithm. This in turn enables
generalization to new data using operations such as `predict` or
`transform`:

```julia
using MLJModels
X, y = make_regression()

PCA = @load PCA pkg=MultivariateStats
model = PCA()
mach = machine(model, X)
fit!(mach, rows=1:50)
transform(mach, selectrows(X, 51:100)) # or transform(mach, rows=51:100)

DecisionTreeRegressor = @load DecisionTreeRegressor pkg=DecisionTree
model = DecisionTreeRegressor()
mach = machine(model, X, y)
fit!(mach, rows=1:50)
predict(mach, selectrows(X, 51:100)) # or predict(mach, rows=51:100)
```

Specify `cache=false` to prioritize memory management over speed, and
to guarantee data anonymity when serializing composite models.

When building a learning network, `Node` objects can be substituted
for the concrete data.

### Learning network machines

    machine(Xs; oper1=node1, oper2=node2, ...)
    machine(Xs, ys; oper1=node1, oper2=node2, ...)
    machine(Xs, ys, extras...; oper1=node1, oper2=node2, ...)

Construct a special machine called a *learning network machine*, that
wraps a learning network, usually in preparation to export the network
as a stand-alone composite model type. The keyword arguments declare
what nodes are called when operations, such as `predict` and
`transform`, are called on the machine. An advanced option allows one
to additionally pass the output of any node to the machine's report;
see below.

In addition to the operations named in the constructor, the methods
`fit!`, `report`, and `fitted_params` can be applied as usual to the
machine constructed.

    machine(Probabilistic(), args...; kwargs...)
    machine(Deterministic(), args...; kwargs...)
    machine(Unsupervised(), args...; kwargs...)
    machine(Static(), args...; kwargs...)

Same as above, but specifying explicitly the kind of model the
learning network is to meant to represent.

Learning network machines are not to be confused with an ordinary
machine that happens to be bound to a stand-alone composite model
(i.e., an *exported* learning network).


### Examples of learning network machines

Supposing a supervised learning network's final predictions are
obtained by calling a node `yhat`, then the code

```julia
mach = machine(Deterministic(), Xs, ys; predict=yhat)
fit!(mach; rows=train)
predictions = predict(mach, Xnew) # `Xnew` concrete data
```

is  equivalent to

```julia
fit!(yhat, rows=train)
predictions = yhat(Xnew)
```

Here `Xs` and `ys` are the source nodes receiving, respectively, the
input and target data.

In a unsupervised learning network for clustering, with single source
node `Xs` for inputs, and in which the node `Xout` delivers the output
of dimension reduction, and `yhat` the class labels, one can write

```julia
mach = machine(Unsupervised(), Xs; transform=Xout, predict=yhat)
fit!(mach)
transformed = transform(mach, Xnew) # `Xnew` concrete data
predictions = predict(mach, Xnew)
```

which is equivalent to

```julia
fit!(Xout)
fit!(yhat)
transformed = Xout(Xnew)
predictions = yhat(Xnew)
```
### Including a node's output in the report

The return value of a node called with no arguments can be included in
a learning network machine's report, and so in the report of any
composite model type constructed by exporting a learning network. This
is useful for exposing byproducts of network training that are not
readily deduced from the `report`s and `fitted_params` of the
component machines (which are automatically exposed).

The following example shows how to expose `err1()` and `err2()`, where
`err1` are `err2` are nodes in the network delivering training errors.

```julia
X, y = make_moons()
Xs = source(X)
ys = source(y)

model = ConstantClassifier()
mach = machine(model, Xs, ys)
yhat = predict(mach, Xs)
err1 = @node auc(yhat, ys)
err2 = @node accuracy(yhat, ys)

network_mach = machine(Probabilistic(),
                       Xs,
                       ys,
                       predict=yhat,
                       report=(auc=err1, accuracy=err2))

fit!(network_mach)
r = report(network_mach)
@assert r.auc == auc(yhat(), ys())
@assert r.accuracy == accuracy(yhat(), ys())
```
"""
function machine end

machine(T::Type{<:Model}, args...; kwargs...) =
    throw(ArgumentError("Model *type* provided where "*
                        "model *instance* expected. "))

static_error() =
    throw(ArgumentError("A `Static` transformer "*
                        "has no training arguments. "*
                        "Use `machine(model)`. "))

function machine(model::Static, args...; kwargs...)
    isempty(args) || static_error()
    return Machine(model; kwargs...)
end

function machine(model::Static, args::AbstractNode...; kwargs...)
    isempty(args) || static_error()
    return Machine(model; kwargs...)
end

machine(model::Model, raw_arg1, arg2::AbstractNode, args::AbstractNode...;
        kwargs...) =
    error("Mixing concrete data with `Node` training arguments "*
          "is not allowed. ")

machine(model::Model, arg1::AbstractNode, arg2, args...; kwargs...) =
    error("Mixing concrete data with `Node` training arguments "*
          "is not allowed. ")

function machine(model::Model, raw_arg1, raw_args...; kwargs...)
    args = source.((raw_arg1, raw_args...))
    check(model, args...; full=true)
    return Machine(model, args...; kwargs...)
end

function machine(model::Model, arg1::AbstractNode, args::AbstractNode...;
                 kwargs...)
    check(model, arg1, args...)
    return Machine(model, arg1, args...; kwargs...)
end


## INSPECTION AND MINOR MANIPULATION OF FIELDS

# Note: freeze! and thaw! are possibly not used within MLJ itself.

"""
    freeze!(mach)

Freeze the machine `mach` so that it will never be retrained (unless
thawed).

See also [`thaw!`](@ref).
"""
function freeze!(machine::Machine)
    machine.frozen = true
end

"""
    thaw!(mach)

Unfreeze the machine `mach` so that it can be retrained.

See also [`freeze!`](@ref).
"""
function thaw!(machine::Machine)
    machine.frozen = false
end

params(mach::Machine) = params(mach.model)

machines(::Source) = Machine[]


## DISPLAY

_cache_status(::Machine{<:Any,true}) = " caches data"
_cache_status(::Machine{<:Any,false}) = " does not cache data"

function Base.show(io::IO, ::MIME"text/plain", mach::Machine{M}) where M
    show(io, mach)
    print(io, " trained $(mach.state) time")
    if mach.state == 1
        print(io, ";")
    else
        print(io, "s;")
    end
    println(io, _cache_status(mach))
    println(io, "  model: $M")
    println(io, "  args: ")
    for i in eachindex(mach.args)
        arg = mach.args[i]
        print(io, "    $i:\t$arg")
        if arg isa Source
            println(io, " \u23CE `$(elscitype(arg))`")
        else
            println(io)
        end
    end
end


## FITTING

# Not one, but *two*, fit methods are defined for machines here,
# `fit!` and `fit_only!`.

# - `fit_only!`: trains a machine without touching the learned
#   parameters (`fitresult`) of any other machine. It may error if
#   another machine on which it depends (through its node training
#   arguments `N1, N2, ...`) has not been trained.

# - `fit!`: trains a machine after first progressively training all
#   machines on which the machine depends. Implicitly this involves
#   making `fit_only!` calls on those machines, scheduled by the node
#   `glb(N1, N2, ... )`, where `glb` means greatest lower bound.)


function fitlog(mach, action::Symbol, verbosity)
    if verbosity < -1000
        put!(MACHINE_CHANNEL, (action, mach))
    elseif verbosity > -1 && action == :frozen
        @warn "$mach not trained as it is frozen."
    elseif verbosity > 0
        action == :train && (@info "Training $mach."; return)
        action == :update && (@info "Updating $mach."; return)
        action == :skip && begin
            @info "Not retraining $mach. Use `force=true` to force."
            return
        end
    end
end

# for getting model specific representation of the row-restricted
# training data from a machine, according to the value of the machine
# type parameter `C` (`true` or `false`):
_resampled_data(mach::Machine{<:Model,true}, rows) = mach.resampled_data
function _resampled_data(mach::Machine{<:Model,false}, rows)
    raw_args = map(N -> N(), mach.args)
    data = MMI.reformat(mach.model, raw_args...)
    return selectrows(mach.model, rows, data...)
end

"""
    MLJBase.fit_only!(mach::Machine; rows=nothing, verbosity=1, force=false)

Without mutating any other machine on which it may depend, perform one of
the following actions to the machine `mach`, using the data and model
bound to it, and restricting the data to `rows` if specified:

- *Ab initio training.* Ignoring any previous learned parameters and
  cache, compute and store new learned parameters. Increment `mach.state`.

- *Training update.* Making use of previous learned parameters and/or
   cache, replace or mutate existing learned parameters. The effect is
   the same (or nearly the same) as in ab initio training, but may be
   faster or use less memory, assuming the model supports an update
   option (implements `MLJBase.update`). Increment `mach.state`.

- *No-operation.* Leave existing learned parameters untouched. Do not
   increment `mach.state`.


### Training action logic

For the action to be a no-operation, either `mach.frozen == true` or
or none of the following apply:

- (i) `mach` has never been trained (`mach.state == 0`).

- (ii) `force == true`.

- (iii) The `state` of some other machine on which `mach` depends has
  changed since the last time `mach` was trained (ie, the last time
  `mach.state` was last incremented).

- (iv) The specified `rows` have changed since the last retraining and
  `mach.model` does not have `Static` type.

- (v) `mach.model` has changed since the last retraining.

In any of the cases (i) - (iv), `mach` is trained ab initio. If only
(v) fails, then a training update is applied.

To freeze or unfreeze `mach`, use `freeze!(mach)` or `thaw!(mach)`.


### Implementation detail

The data to which a machine is bound is stored in `mach.args`. Each
element of `args` is either a `Node` object, or, in the case that
concrete data was bound to the machine, it is concrete data wrapped in
a `Source` node. In all cases, to obtain concrete data for actual
training, each argument `N` is called, as in `N()` or `N(rows=rows)`,
and either `MLJBase.fit` (ab initio training) or `MLJBase.update`
(training update) is dispatched on `mach.model` and this data. See the
"Adding models for general use" section of the MLJ documentation for
more on these lower-level training methods.

"""
function fit_only!(mach::Machine{<:Model,cache_data};
                   rows=nothing,
                   verbosity=1,
                   force=false) where cache_data

    if mach.frozen
        # no-op; do not increment `state`.
        fitlog(mach, :frozen, verbosity)
        return mach
    end

    # catch deserialized machines not bound to data:
    !(mach.model isa Static) && isempty(mach.args) &&
        error("This machine is not bound to any data and so "*
              "cannot be trained. ")

    # take action if model has been mutated illegally:
    warning = clean!(mach.model)
    isempty(warning) || verbosity < 0 || @warn warning

    upstream_state = upstream(mach)

    rows === nothing && (rows = (:))
    rows_is_new = !isdefined(mach, :old_rows) || rows != mach.old_rows

    condition_iv = rows_is_new && !(mach.model isa Static)

    upstream_has_changed = mach.old_upstream_state != upstream_state

    data_is_valid = isdefined(mach, :data) && !upstream_has_changed

    # build or update cached `data` if necessary:
    if cache_data && !data_is_valid
        raw_args = map(N -> N(), mach.args)
        mach.data = MMI.reformat(mach.model, raw_args...)
    end

    # build or update cached `resampled_data` if necessary:
    if cache_data && (!data_is_valid || condition_iv)
        mach.resampled_data = selectrows(mach.model, rows, mach.data...)
    end

    # `fit`, `update`, or return untouched:
    if mach.state == 0 ||       # condition (i)
        force == true ||        # condition (ii)
        upstream_has_changed || # condition (iii)
        condition_iv

        # fit the model:
        fitlog(mach, :train, verbosity)
        mach.fitresult, mach.cache, mach.report =
            try
                fit(mach.model, verbosity, _resampled_data(mach, rows)...)
            catch exception
                @error "Problem fitting the machine $mach. "
                _sources = sources(glb(mach.args...))
                length(_sources) > 2 ||
                    mach.model isa Composite ||
                    all((!isempty).(_sources)) ||
                    @warn "Some learning network source nodes are empty. "
                @info "Running type checks... "
                raw_args = map(N -> N(), mach.args)
                if check(mach.model, source.(raw_args)... ; full=true)
                    @info "Type checks okay. "
                else
                @info "It seems an upstream node in a learning "*
                    "network is providing data of incompatible scitype. See "*
                    "above. "
                end
                rethrow()
            end

    elseif mach.model != mach.old_model # condition (v)

        # update the model:
        fitlog(mach, :update, verbosity)
        mach.fitresult, mach.cache, mach.report =
            update(mach.model,
                   verbosity,
                   mach.fitresult,
                   mach.cache,
                   _resampled_data(mach, rows)...)

    else

        # don't fit the model and return without incrementing `state`:
        fitlog(mach, :skip, verbosity)
        return mach

    end

    # If we get to here it's because we have run `fit` or `update`!

    if rows_is_new
        mach.old_rows = deepcopy(rows)
    end

    mach.old_model = deepcopy(mach.model)
    mach.old_upstream_state = upstream_state
    mach.state = mach.state + 1

    return mach
end

"""

    fit!(mach::Machine, rows=nothing, verbosity=1, force=false)

Fit the machine `mach`. In the case that `mach` has `Node` arguments,
first train all other machines on which `mach` depends.

To attempt to fit a machine without touching any other machine, use
`fit_only!`. For more on the internal logic of fitting see
[`fit_only!`](@ref)

"""
function fit!(mach::Machine; kwargs...)
    glb_node = glb(mach.args...) # greatest lower bound node of arguments
    fit!(glb_node; kwargs...)
    fit_only!(mach; kwargs...)
end

# version of fit_only! for calling by scheduler (a node), which waits
# on the specified `machines` to fit:
function fit_only!(mach::Machine, wait_on_downstream::Bool; kwargs...)

    wait_on_downstream || fit_only!(mach; kwargs...)

    upstream_machines = machines(glb(mach.args...))

    # waiting on upstream machines to fit:
    for m in upstream_machines
        fit_okay = fetch(m.fit_okay)
        if !fit_okay
            put!(mach.fit_okay, false)
            return mach
        end
    end

    # try to fit this machine:
    try
        fit_only!(mach; kwargs...)
    catch e
        put!(mach.fit_okay, false)
        @error "Problem fitting $mach"
        throw(e)
    end
    put!(mach.fit_okay, true)
    return mach

end


## INSPECTION OF TRAINING OUTCOMES

"""
    fitted_params(mach)

Return the learned parameters for a machine `mach` that has been
`fit!`, for example the coefficients in a linear model.

This is a named tuple and human-readable if possible.

If `mach` is a machine for a composite model, such as a model
constructed using `@pipeline`, then the returned named tuple has the
composite type's field names as keys. The corresponding value is the
fitted parameters for the machine in the underlying learning network
bound to that model. (If multiple machines share the same model, then the
value is a vector.)

```julia
using MLJ
@load LogisticClassifier pkg=MLJLinearModels
X, y = @load_crabs;
pipe = @pipeline Standardizer LogisticClassifier
mach = machine(pipe, X, y) |> fit!

julia> fitted_params(mach).logistic_classifier
(classes = CategoricalArrays.CategoricalValue{String,UInt32}["B", "O"],
 coefs = Pair{Symbol,Float64}[:FL => 3.7095037897680405, :RW => 0.1135739140854546, :CL => -1.6036892745322038, :CW => -4.415667573486482, :BD => 3.238476051092471],
 intercept = 0.0883301599726305,)
```

Additional keys, `machines` and `fitted_params_given_machine`, give a
list of *all* machines in the underlying network, and a dictionary of
fitted parameters keyed on those machines.

```

"""
function fitted_params(mach::Machine)
    if isdefined(mach, :fitresult)
        return fitted_params(mach.model, mach.fitresult)
    else
        throw(NotTrainedError(mach, :fitted_params))
    end
end

"""
    report(mach)

Return the report for a machine `mach` that has been
`fit!`, for example the coefficients in a linear model.

This is a named tuple and human-readable if possible.

If `mach` is a machine for a composite model, such as a model
constructed using `@pipeline`, then the returned named tuple has the
composite type's field names as keys. The corresponding value is the
report for the machine in the underlying learning network
bound to that model. (If multiple machines share the same model, then the
value is a vector.)

```julia
using MLJ
@load LinearBinaryClassifier pkg=GLM
X, y = @load_crabs;
pipe = @pipeline Standardizer LinearBinaryClassifier
mach = machine(pipe, X, y) |> fit!

julia> report(mach).linear_binary_classifier
(deviance = 3.8893386087844543e-7,
 dof_residual = 195.0,
 stderror = [18954.83496713119, 6502.845740757159, 48484.240246060406, 34971.131004997274, 20654.82322484894, 2111.1294584763386],
 vcov = [3.592857686311793e8 9.122732393971942e6 … -8.454645589364915e7 5.38856837634321e6; 9.122732393971942e6 4.228700272808351e7 … -4.978433790526467e7 -8.442545425533723e6; … ; -8.454645589364915e7 -4.978433790526467e7 … 4.2662172244975924e8 2.1799125705781363e7; 5.38856837634321e6 -8.442545425533723e6 … 2.1799125705781363e7 4.456867590446599e6],)

```

Additional keys, `machines` and `report_given_machine`, give a
list of *all* machines in the underlying network, and a dictionary of
reports keyed on those machines.

```

"""
function report(mach::Machine)
    if isdefined(mach, :report)
        return mach.report
    else
        throw(NotTrainedError(mach, :report))
    end
end


"""
    training_losses(mach::Machine)

Return a list of training losses, for models that make these
available. Otherwise, returns `nothing`.

"""

function training_losses(mach::Machine)
    if isdefined(mach, :report)
        return training_losses(mach.model, mach.report)
    else
        throw(NotTrainedError(mach, :training_losses))
    end
end
