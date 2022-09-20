using Bonsai
using Bonsai: combine_middleware, Middleware
using URIs
using Dates
using HTTP: Request

t = false
c = false

@testset "combine_middleware" begin

	function timer(stream, next)
		x = now()
		next(stream)
		elapsed = x - now()
		global t
		t = true
	end

	function cors(stream, next)
		next(stream)
		global c
		c = true
	end

	fn = combine_middleware([timer, cors ])
	fn(nothing)
	@test c && t
	@test combine_middleware([])(true)
end

@testset "multple_middleware" begin
	l = [false, false]
	app = App()

	function fn1(stream, next)
		l[1] = true
	end

	function fn2(stream, next)
		l[2] = true
	end

	app.get["**"] = [fn1, fn2]

	@test length(app.get["**"][2]) == 2
end