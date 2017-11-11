
import IndexedTables: convertdim, aggregate, aggregate_vec, reducedim_vec, pick
import Base: reducedim, mapslices, aggregate

# re-export
export pick

# Filter on data field
"""
    filter(f, t::DNDSparse)

Filters `t` removing rows for which `f` is false. `f` is passed only the data
and not the index.
"""
function Base.filter(f, t::DNDSparse)
    cache_thunks(mapchunks(x -> filter(f, x), t, keeplengths=false))
end

"""
    convertdim(x::DNDSparse, d::DimName, xlate; agg::Function, name)

Apply function or dictionary `xlate` to each index in the specified dimension.
If the mapping is many-to-one, `agg` is used to aggregate the results.
`name` optionally specifies a name for the new dimension. `xlate` must be a
monotonically increasing function.

See also [`reducedim`](@ref) and [`aggregate`](@ref)
"""
function convertdim(t::DNDSparse{K,V}, d::DimName, xlat;
                    agg=nothing, vecagg=nothing, name=nothing) where {K,V}

    if isa(d, Symbol)
        dn = findfirst(dimlabels(t), d)
        if dn == 0
            throw(ArgumentError("table has no dimension \"$d\""))
        end
        d = dn
    end

    chunkf(c) = convertdim(c, d, xlat; agg=agg, vecagg=nothing, name=name)
    chunks = map(delayed(chunkf), t.chunks)

    xlatdim(intv, d) = Interval(tuplesetindex(first(intv), xlat(first(intv)[d]), d),
                                tuplesetindex(last(intv),  xlat(last(intv)[d]), d))

    # TODO: handle name kwarg
    # apply xlat to bounding rectangles
    domains = map(t.domains) do space
        nrows = agg === nothing ? space.nrows : Nullable{Int}()
        IndexSpace(xlatdim(space.interval, d), xlatdim(space.boundingrect, d), nrows)
    end

    t1 = DNDSparse{eltype(domains[1]),V}(domains, chunks)

    if agg !== nothing && has_overlaps(domains)
        overlap_merge(x, y) = merge(x, y, agg=agg)
        chunk_merge(ts...)  = _merge(overlap_merge, ts...)
        cache_thunks(rechunk(t1, merge=chunk_merge, closed=true))
    elseif vecagg != nothing
        groupby(vecagg, t1) # already cached
    else
        cache_thunks(t1)
    end
end

keyindex(t::DNDSparse, i::Int) = i
keyindex(t::DNDSparse{K}, i::Symbol) where {K} = findfirst(x->x===i, fieldnames(K))

function mapslices(f, x::DNDSparse, dims; name=nothing)
    iterdims = setdiff([1:ndims(x);], map(d->keyindex(x, d), dims))
    if iterdims != [1:length(iterdims);]
        throw(ArgumentError("$dims must be the trailing dimensions of the table. You can use `permutedims` first to permute the dimensions."))
    end

    # Note: the key doesn't need to be put in a tuple, this is
    # also bad for sortperm, but is required since DArrays aren't
    # parameterized by the container type Columns
    tmp = ndsparse((keys(x, (iterdims...)),), (keys(x, (dims...)), values(x)))

    cs = delayedmap(tmp.chunks) do c
        y = ndsparse(IndexedTables.concat_cols(columns(keys(c))[1], columns(values(c))[1]), columns(values(c))[2])
        mapslices(f, y, dims; name=nothing)
    end
    fromchunks(cs)
  # cache_thunks(mapchunks(y -> mapslices(f, y, dims, name=name),
  #                        t, keeplengths=false))
end

mapslices(f, x::DNDSparse, dims::Symbol; name=nothing) =
    mapslices(f, x, (dims,); name=name)
