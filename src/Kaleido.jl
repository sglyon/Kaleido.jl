module Kaleido

import PlotlyBase, JSON, Base64

const BIN = `$(joinpath(dirname(dirname(@__FILE__)), "kaleido", "kaleido")) plotly --disable-gpu`

mutable struct Pipes
    stdin :: Pipe
    stdout :: Pipe
    stderr :: Pipe
    proc :: Base.Process
    Pipes() = new()
end

const P = Pipes()

const ALL_FORMATS = ["png", "jpg", "jpeg", "webp", "svg", "pdf", "eps", "json"]
const TEXT_FORMATS = ["svg", "json", "eps"]

function _restart_process()
    if process_running(P.proc)
        kill(P.proc)
    end
    _start_process()
end


function _start_process()
    global P
    try
        kstdin = Pipe()
        kstdout = Pipe()
        kstderr = Pipe()
        kproc = run(pipeline(BIN,
                             stdin = kstdin, stdout = kstdout, stderr = kstderr),
                    wait = false)
        process_running(kproc) || error("There was a problem startink up kaleido.")
        close(kstdout.in)
        close(kstderr.in)
        close(kstdin.out)
        Base.start_reading(kstderr.out)
        P.stdin = kstdin
        P.stdout = kstdout
        P.stderr = kstderr
        P.proc = kproc

        # read startup message and check for errors
        res = readline(P.stdout)
        if length(res) == 0
            error("Could not start Kaledio process")
        end

        js = JSON.parse(res)
        if get(js, "code", 0) != 0
            error("Could not start Kaledio process")
        end
    catch
        @warn "Kaledio is not available on this system. Julia will be unable to produce any plots."
    end
    nothing
end

# initialize kaleido
function __init__()
    _start_process()
    return nothing
end


function PlotlyBase.savefig(
        p::PlotlyBase.Plot;
        width::Union{Nothing,Int}=nothing,
        height::Union{Nothing,Int}=nothing,
        scale::Union{Nothing,Real}=nothing,
        format::String="png"
    )::Vector{UInt8}
    if !(format in ALL_FORMATS)
        error("Unknown format $format. Expected one of $ALL_FORMATS")
    end

    # construct payload
    _get(x, def) = x === nothing ? def : x
    payload = Dict(
        :width => _get(width, 700),
        :height => _get(height, 500),
        :scale => _get(scale, 1),
        :format => format,
        :data => p
    )

    _ensure_running()

    # convert payload to vector of bytes
    bytes = transcode(UInt8, JSON.json(payload))
    write(P.stdin, bytes)
    write(P.stdin, transcode(UInt8, "\n"))
    flush(P.stdin)

    # read stdout and parse to json
    res = readline(P.stdout)
    js = JSON.parse(res)

    # check error code
    code = get(js, "code", 0)
    if code != 0
        msg = get(js, "message", nothing)
        error("Transform failed with error code $code: $msg")
    end

    # get raw image
    img = String(js["result"])

    # base64 decode if needed, otherwise transcode to vector of byte
    if format in TEXT_FORMATS
        return transcode(UInt8, img)
    else
        return Base64.base64decode(img)
    end
end

function PlotlyBase.savefig(io::IO,
        p::PlotlyBase.Plot;
        width::Union{Nothing,Int}=nothing,
        height::Union{Nothing,Int}=nothing,
        scale::Union{Nothing,Real}=nothing,
        format::String="png")

    format == "html" && return PlotlyBase.savehtml(io, p)

    bytes = PlotlyBase.savefig(p, width=width, height=height, scale=scale, format=format)
    write(io, bytes)
end

"""
    savefig(p::Plot, fn::AbstractString; format=nothing, scale=nothing,
    width=nothing, height=nothing)
Save a plot `p` to a file named `fn`. If `format` is given and is one of
(png, jpeg, webp, svg, pdf, eps), it will be the format of the file. By
default the format is guessed from the extension of `fn`. `scale` sets the
image scale. `width` and `height` set the dimensions, in pixels. Defaults
are taken from `p.layout`, or supplied by plotly
"""
function PlotlyBase.savefig(
        p::PlotlyBase.Plot, fn::AbstractString;
        format::Union{Nothing,String}=nothing,
        width::Union{Nothing,Int}=nothing,
        height::Union{Nothing,Int}=nothing,
        scale::Union{Nothing,Real}=nothing,
    )
    ext = split(fn, ".")[end]
    if format === nothing
        format = String(ext)
    end

    open(fn, "w") do f
        PlotlyBase.savefig(f, p; format=format, scale=scale, width=width, height=height)
    end
    return fn
end

_is_running() = isopen(P.stdin) && process_running(P.proc)
_ensure_running() = !_is_running() && _restart_process()

end # module
