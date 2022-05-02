using Bonsai, URIs, StructTypes
using JSON3
using StructTypes: @Struct

app = App()

@Struct struct Id 
	id::Int
end

@Struct struct Limit 
	limit::Int
	offset::Union{Int, Missing}
end

@Struct struct Pet
	id::Int
	name::String
	tag::String
end

@Struct struct Error 
	code::Int
	type::String
end

@Struct struct Next
	x_next::String
end

pets = Dict(
	1 =>  Pet(
		1,
		"bobby",
		"dog"
	)
)

app.post("/pets/{id}") do stream
	pet = Bonsai.read(stream, Body(Pet))
	pets[pet.id] = pet
	@info "created pet" pet=pet
	Bonsai.write(stream, "ok")
end

app.get("/pets/{id}") do stream
	id = Bonsai.read(stream, PathParams(Id)).id
	if haskey(pets, id)
		pet::Pet = pets[id]
		Bonsai.write(stream, pet, ResponseCodes.Ok())
	else
		err = Error(
			1,
			"Pet not found :("
		)
		Bonsai.write(stream, err, ResponseCodes.NotFound())
	end
end


app.get("/pets") do stream
	query = Bonsai.read(stream, Query(Limit))
	l = Pet[]

	for (i, pet) in values(pets)

		if !ismissing(query.offset) & i < query.offset
			continue
		end

		push!(l, pet)
		if i > query.limit
			break
		end
	end

	Bonsai.write(stream, Headers(Next("/pets?limit=$(query.limit+1)&offset=$(query.offset)")))
	Bonsai.write(stream, l)
end

app.get("*") do stream, next
	try
		next(stream)
		if isopen(stream) && !iswritable(stream)
            error("Server never wrote a response")
        end
	catch e
		@error e
		Bonsai.write(stream, string(e), ResponseCodes.InternalServerError())
	end
end

OpenAPI(app)

start(app, port=10002)
wait(app)
stop(app)

