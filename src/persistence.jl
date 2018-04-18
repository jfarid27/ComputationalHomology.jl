abstract type AbstractPersistenceReduction end
mutable struct StandardReduction <: AbstractPersistenceReduction end
mutable struct TwistReduction <: AbstractPersistenceReduction end

const Interval = Pair{Number,Number}
Base.show(io::IO, intr::Interval) = print(io, "[$(intr[1]),$(intr[2]))")

lastindex(col::IntSet) = length(col) == 0 ? -1 : last(col)

"""Standart reduction"""
function Base.reduce(::Type{StandardReduction}, ∂::Vector{IntSet})
    lowest_one_lookup = fill(-1, length(∂))
    for col in eachindex(∂)
        lowest_one = lastindex(∂[col])
        while lowest_one != -1 && lowest_one_lookup[lowest_one] != -1
            lowest = lowest_one_lookup[lowest_one]
            symdiff!(∂[col], ∂[lowest])
            lowest_one = lastindex(∂[col])
        end
        if lowest_one != -1
            lowest_one_lookup[lowest_one] = col
        end
    end
    return ∂
end

"""Twist reduction"""
function Base.reduce(::Type{TwistReduction}, ∂::Vector{IntSet})
    lowest_one_lookup = fill(-1, length(∂))

    for dim in maximum(map(length, ∂)):-1:1
        for col in eachindex(∂)
            if length(∂[col]) == dim
                lowest_one = lastindex(∂[col])
                while lowest_one != -1 && lowest_one_lookup[lowest_one] != -1
                    lowest = lowest_one_lookup[lowest_one]
                    symdiff!(∂[col], ∂[lowest])
                    lowest_one = lastindex(∂[col])
                end
                if lowest_one != -1
                    lowest_one_lookup[lowest_one] = col
                end
            end
        end
    end
    return ∂
end

function generate_pairs(∂::Vector)
    pairs = Pair{Int,Int}[]
    for col in eachindex(∂)
        if length(∂[col]) > 0
            birth = last(∂[col])
            death = col
            push!(pairs, birth=>death)
        end
    end
    return pairs
end

function generate_pairs(∂::Vector{IntSet}; reduced = false)
    ridx = reduced ? 1 : 0
    births = IntSet()
    pairs = Interval[]
    for i in eachindex(∂)
        if length(∂[i]) > 0
            b = last(∂[i])
            d = i
            delete!(births, b)
            delete!(births, d)
            (d > b) && push!(pairs, (b-ridx)=>(d-ridx))
        else
            push!(births, i)
        end
    end
    for i in births # no lowest, create semi-infinite interval
        push!(pairs, (i-ridx)=>Inf)
    end
    return pairs
end

"Compute raw persistence pairs (boundary matrix is reduced in a process)"
function pairs(::Type{R}, ∂::Vector{IntSet}; reduced = false) where {R <: AbstractPersistenceReduction}
    reduce(R, ∂) # reduce  boundary matrix
    return generate_pairs(∂, reduced=reduced), ∂  # generate pairs
end

pairs(::Type{R}, flt::Filtration; reduced = false) where {R <: AbstractPersistenceReduction} =
    pairs(R, boundary_matrix(flt, reduced = reduced), reduced = reduced)

"""Return birth-death pairs per dimension"""
function intervals(flt::Filtration, ps::Vector{Interval}; length0=false)
    cdim = dim(complex(flt))

    # construct intervals from filtration index pairs
    intrs = Dict{Int,Vector{Interval}}()
    for (b,d) in ps
        s, e = if !isinf(d)
            flt.total[b][3], flt.total[d][3]
        else
            flt.total[b][3], d
        end
        (length0 ? (s > e) : (s >= e))  && continue
        # println("$s => $e ($b => $d)")

        idim = flt.total[b][1]
        if 0 <= idim < cdim
            !haskey(intrs, idim) && setindex!(intrs, Vector{Interval}(), idim)
            push!(intrs[idim], s => e)
        end
    end

    return intrs
end

function intervals(flt::Filtration; reduction=TwistReduction, reduced=false, length0=false)
    ps, ∂ = pairs(reduction, flt, reduced=reduced)
    return intervals(flt, ps, length0=length0)
end

"Calculate persistent Betti numbers for a filtration complex of dimension `dim`"
function betti(∂::Vector, R::Vector, p::Int)
    simdim(s) = length(s) == 0 ? 0 : length(s)-1
    sdims = map(simdim, ∂)
    @assert maximum(sdims) >= p "Cannot calculate $p-dimensional Betti number for $(maximum(sdims))-complex"

    # the number of zero columns that correspond to p-simplices
    # z = mapreduce(i->length(R[i]) == 0 ? 1 : 0, +, find(d->d==p, sdims))

    RR = spzeros(Int, length(R), length(R))
    for (j, I) in enumerate(R)
        lasti = 0
        for i in I
            lasti = i+1
            RR[lasti,j] = 1
        end
        if lasti > 0
            RR[lasti,j] = 2
        end
    end
    p2i = find(d->d==p, sdims)
    # the number of zero columns that correspond to p-simplices
    z = find(i->i==0, sum(RR[:,p2i],1)) |> length
    # the number of lowest ones in rows that correspond to p-simplices
    l = find(i->i==2, RR[p2i,:]) |> length
    β = z - l
    return β < 0 ? 0 : β
end

"""
Persistent homology group iterator for a filtration
"""
mutable struct PersistentHomology{G} <: AbstractHomology{G}
    filtration::Filtration
    reduction::DataType
    ∂::Vector{IntSet}
    R::Vector{IntSet}
    reduced::Bool
end
persistenthomology(::Type{R}, ::Type{G}, flt::Filtration; reduced=false) where {R <: AbstractPersistenceReduction, G} =
    PersistentHomology{G}(flt, R, Vector{IntSet}(), Vector{IntSet}(), reduced)
persistenthomology(::Type{R}, flt::Filtration; reduced::Bool=false) where {R <: AbstractPersistenceReduction} =
    persistenthomology(R, Int, flt, reduced=reduced)

Base.show(io::IO, h::PersistentHomology) = print(io, "PersistentHomology[$(h.filtration) with $(h.reduction)]")

"""Return homology group type: dimension & Betti numbers."""
Base.eltype(::Type{PersistentHomology{G}}) where {G} = Tuple{Int, Int}

#
# Interface methods
#

function group(h::PersistentHomology, p::Int)
    if length(h.∂) == 0
        h.∂ = boundary_matrix(h.filtration, reduced=h.reduced)
    end
    if length(h.R) == 0
        h.R = reduce(h.reduction, deepcopy(h.∂))
    end
    return betti(h.∂, h.R, p)
end

#
# Iterator methods
#

Base.length(h::PersistentHomology) = dim(h.filtration.complex)+1
Base.start(h::PersistentHomology) = 0
Base.done(h::PersistentHomology, state) = dim(h.filtration.complex) < state[1]
function Base.next(h::PersistentHomology, state)
    p = state[1]
    βₚ = group(h, p)
    return (p, βₚ), p+1
end
