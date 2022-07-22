using JET.JETInterface
using Base.Core
using StructTypes
import JET:
    JET,
    @invoke,
    isexpr

using HTTP: Stream
using FilePathsBase: AbstractPath
import Parsers

const CC = Core.Compiler

# avoid kwargs in write due as it makes the analysis more complicated
# https://github.com/JuliaLang/julia/issues/9551
# https://discourse.julialang.org/t/untyped-keyword-arguments/24228
# https://discourse.julialang.org/t/closure-over-a-function-with-keyword-arguments-while-keeping-access-to-the-keyword-arguments/15574

function construct_error(T::DataType, d)
    struct_keys = collect(fieldnames(T))
    data_keys = collect(keys(d))
    ks = Symbol[]

    for k in struct_keys
        if !(k in data_keys)
            push!(ks, k)
        end
    end

    if isempty(ks)
        return nothing
    else
        return DataMissingKey(T,
            sort!(struct_keys),
            sort!(data_keys),
        )
    end
end


const default_status = Status(:default)

# write(res, data, status_code::Integer) = write(res, data, Val(status_code))

# We are passing status code so that the generated OpenAPI docs knows status code
# these headers are associated with however we don't write it. This feels a little messy 
# there may be a better way to associate the status code, perhaps the type itself should
# have the code Body{T, Val{200}}() or Headers{T, Val{200}}().

# However these parametric types feels a little like rust generics a bit verbose, 
# this is fine if the burden of constructing them doesn't fall to heavily on the user

function write(res::Response, headers::Headers{T}) where {T}
    val = headers.val
    if !isnothing(val)
        for (header, value) in zip(fieldnames(val), fieldvalues(val))
            HTTP.setheader(res, headerize(header) => value)
        end
    end
end

function write(res::Response, data::Body{T}) where {T}
    if StructTypes.StructType(T) == StructTypes.NoStructType()
        error("Unsure how to write type $T to stream")
    else
        if !isnothing(data.val)
            b = IOBuffer()
            JSON3.write(b, data.val, allow_inf=true)
            res.body = take!(b)
        end

        m = mime_type(T)
        if !isnothing(m)
            write(res, Headers(content_type=m))
        end
    end
end

function write(res::Response, path::AbstractPath)
    body = Base.read(path)
    res.body = body
    m = mime_type(path)
    if !isnothing(m)
        write(res, Headers(content_type=m))
    end
end

function write(stream::Response, data::T) where {T}
    if StructTypes.StructType(T) != StructTypes.NoStructType()
        write(stream, Body(T))
        write(stream, Status(200))
    elseif T isa Exception
        write(stream, Body(string(data)))
        write(stream, Status(500))
    else
        error("Unable in infer correct write location please wrap in Body or Headers")
    end
end

write(stream::Stream{<:Request}, data) = write(stream.message.response, data)
write(stream::Stream{<:Request}, data...) = write(stream.message.response, data...)
write(res::Response, ::Status{T}) where T =  res.status = Int(T)
write(res::Response, ::Status{:default})  =  res.status = 200

read(stream::Stream{<:Request}, b::Body{T}) where {T} = read(stream.message, b)
read(stream::Stream{A,B}, b) where {A<:Request,B} = read(stream.message, b)


# This function could be the entry point for the static analysis writes
# allow us to group together headers and status codes etc
function write(res::Response, args...) 
    @assert args isa Tuple{Vararg{<:HttpParameter}}
    for i in args
        write(res, i)
    end
end

function read(req::Request, ::Body{T}) where {T}
    d = JSON3.read(req.body)
    try
        return StructTypes.constructfrom(T, d)
    catch e
        maybe_e = construct_error(T, d)
        if isnothing(e)
            rethrow(e)
        else
            throw(maybe_e)
        end
    end
end

function construct_data(data, T::DataType)
    convert_numbers!(data, T)
    StructTypes.constructfrom(T, data)
end

function read(req::Request, ::Params{T}) where {T}
    try
        if hasfield(Request, :context)
            d = req.context[:params]
            return construct_data(d, T)
        else
            error("Params not supported on this version of HTTP")
        end
    catch e
        @debug "Failed to convert path params into $T"
        rethrow(e)
    end
end

function convert_numbers!(data::AbstractDict, T)
    for (k, t) in zip(fieldnames(T), fieldtypes(T))
        if t <: Union{Number, Missing, Nothing}
            data[k] = Parsers.parse(Float64, data[k])
        end
    end
    data
end

function read(req::Request, ::Query{T}) where {T}
    try
        q::Dict{Symbol,Any} = Dict(Symbol(k) => v for (k, v) in queryparams(req.url))
        return construct_data(q, T)
    catch e
        @debug "Failed to convert query into $T"
        rethrow(e)
    end
end

function read(req::Request, ::Headers{T}) where {T}
    fields = fieldnames(T)
    d = Dict{Symbol,Any}()

    for i in fields
        h = headerize(i)
        if HTTP.hasheader(req, h)
            d[i] = HTTP.header(req, h)
        else
            d[i] = missing
        end
    end

    try
        return construct_data(d, T)
    catch e
        rethrow(e)
    end
end

struct DispatchAnalyzer{T} <: AbstractAnalyzer
    state::AnalyzerState
    opts::BitVector
    frame_filter::T
    __cache_key::UInt
end


function DispatchAnalyzer(;
    ## a predicate, which takes `CC.InfernceState` and returns whether we want to analyze the call or not
    frame_filter=x::Core.MethodInstance -> true,
    jetconfigs...)
    state = AnalyzerState(; jetconfigs...)
    ## we want to run different analysis with a different filter, so include its hash into the cache key
    cache_key = state.param_key
    cache_key = hash(frame_filter, cache_key)
    return DispatchAnalyzer(state, BitVector(), frame_filter, cache_key)
end

## AbstractAnalyzer API requirements
JETInterface.AnalyzerState(analyzer::DispatchAnalyzer) = analyzer.state
JETInterface.AbstractAnalyzer(analyzer::DispatchAnalyzer, state::AnalyzerState) = DispatchAnalyzer(state, analyzer.opts, analyzer.frame_filter, analyzer.__cache_key)
JETInterface.ReportPass(analyzer::DispatchAnalyzer) = DispatchAnalysisPass()
JETInterface.get_cache_key(analyzer::DispatchAnalyzer) = analyzer.__cache_key

struct DispatchAnalysisPass <: ReportPass end
## ignore all reports defined by JET, since we'll just define our own reports
(::DispatchAnalysisPass)(T::Type{<:InferenceErrorReport}, @nospecialize(_...)) = return


function CC.finish!(analyzer::DispatchAnalyzer, frame::Core.Compiler.InferenceState)

    caller = frame.result

    ## get the source before running `finish!` to keep the reference to `OptimizationState`
    src = caller.src
    ## run `finish!(::AbstractAnalyzer, ::CC.InferenceState)` first to convert the optimized `IRCode` into optimized `CodeInfo`
    ret = @invoke CC.finish!(analyzer::AbstractAnalyzer, frame::CC.InferenceState)

    if analyzer.frame_filter(frame.linfo)
        ReportPass(analyzer)(IoReport, analyzer, caller, src)
    end

    return ret
end

@reportdef struct IoReport <: InferenceErrorReport
    slottypes
end

JETInterface.print_report(::IO, ::IoReport) =  "detected io" 


ref = Ref{Any}()

function (::DispatchAnalysisPass)(::Type{IoReport}, analyzer::DispatchAnalyzer, caller::CC.InferenceResult, opt::CC.OptimizationState)
    (; src, linfo, slottypes, sptypes) = opt

    # In slottypes the first argument is the function name
    # the remaining are the arguments

    fn = get(slottypes, 1, nothing)
    if fn == Core.Const((@__MODULE__).read)

        add_new_report!(analyzer, caller, IoReport(caller, slottypes))

    elseif fn == Core.Const((@__MODULE__).write)

        ref[] = opt


        status_code = get(slottypes, 4, nothing)

        # println("STATUS CODE: ", status_code)

        if !(status_code isa Core.Const)
            return
        end

        data = get(slottypes, 3, nothing)
        if !(data isa Type)
            return
        end

        add_new_report!(analyzer, caller, IoReport(caller, slottypes))
    end
end

extract_type(::Type{T}) where {T} = T

function handler_writes(@nospecialize(handler))
    calls = JET.report_call(handler, Tuple{Stream}, analyzer=DispatchAnalyzer)
    reports = JET.get_reports(calls)
    fn = Core.Const((@__MODULE__).write)
    filter!(x -> x.slottypes[1] == fn, reports)
    l = map(reports) do r
        res_type = r.slottypes[3]
        res_code = r.slottypes[4].val
        (extract_type(res_type), res_code)
    end
    filter!(x -> x[1] != Any, l)
    unique!(l)
end


function handler_reads(@nospecialize(handler))
    calls = JET.report_call(handler, Tuple{Stream}, analyzer=DispatchAnalyzer)
    reports = JET.get_reports(calls)
    fn = Core.Const((@__MODULE__).read)
    filter!(x -> x.slottypes[1] == fn, reports)

    l = map(reports) do r
        res_type = r.slottypes[3]
        # extracts the type from Core.Const
        res_type = CC.widenconst(res_type)
        return res_type
    end
    unique!(l)
end

handler_reads(handler::AbstractHandler) = handler_reads(handler.fn)

