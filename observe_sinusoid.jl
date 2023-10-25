# Now, we define a model which generates a sinusoid given parameters ``\theta``: an
# amplitude and a vertical shift. The model adds a random phase shift upon evaluation.
using WAVI, Interpolations


# We then define ``G(\theta)``, which returns the observables of the sinusoid
# given a parameter vector. These observables should be defined such that they
# are informative about the parameters we wish to estimate. Here, the two
# observables are the ``y`` range of the curve (which is informative about its
# amplitude), as well as its mean (which is informative about its vertical shift).

# The function parameter_to_data_map takes in the ensemble parameters and returns the observation associated with these parameters. In this case, it's the sea level rise at the end of the simulation
function parameter_to_data_map(ensemble_parameters, member_path)
    slr = driver(ensemble_parameters, member_path)
    return slr
end

function driver(ensemble_parameters, member_path)

function driver()

#
#Grid and boundary conditions
#
nx = 150
ny = 25
nσ = 4
x0 = 0.0
y0 = -25000.0
dx = 2000.0
dy = 2000.0
h_mask=trues(nx,ny)

#
# boundary conditions
#
u_iszero = falses(nx+1,ny);
u_iszero[1,:].=true #xero u flow at x = 0
v_iszero=falses(nx,ny+1);
v_iszero[:,1].=true;        #zero v flow at y =  25km
v_iszero[:,end].=true       #zero v flow at y = -25km
u_iszero[:,1].=true;
u_iszero[:,end].=true;      #no u velocity at lateral boundaries

grid = Grid(nx = nx,
            ny = ny,
            nσ = nσ,
            x0 = x0,
            y0 = y0,
            dx = dx,
            dy = dy,
            h_mask = h_mask,
            u_iszero = u_iszero,
            v_iszero = v_iszero)

#
#Bed
#
bathy=Array{Float64}(undef,nx,ny);
read!("bathy.bin",bathy)
bathy.=ntoh.(bathy)

#
# initial conditions
#
h=Array{Float64}(undef,nx,ny);
read!("initial_thickness.bin",h)
h.=ntoh.(h)
initial_conditions = InitialConditions(initial_thickness = h)

#
#solver parameters
#
maxiter_picard = 3
#parallel_spec = SharedMemorySpec(ngridsx=2,ngridsy=1,overlap=1,damping=0.0,nite
rations=1)
parallel_spec = BasicParallelSpec()
solver_params = SolverParams(maxiter_picard = maxiter_picard)

#
#Physical parameters
#
accumulation =Array{Float64}(undef,nx,ny);
read!("accumulation.bin",accumulation)
accumulation.=ntoh.(accumulation)

weertman_c = 368.0
weertman_c_prefactor = ensemble_parameters["weertman_c_prefactor"]
weertman_c = weertman_c*weertman_c_prefactor


glen_a_ref_prefactor = ensemble_parameters["glen_a_ref_prefactor"]
glen_a_ref =Array{Float64}(undef,nx,ny);
read!("glen_a_ref.bin",glen_a_ref)
glen_a_ref.=ntoh.(glen_a_ref)
glen_a_ref = glen_a_ref_prefactor .* glen_a_ref

params = Params(accumulation_rate = accumulation,
                                  glen_a_ref = glen_a_ref,
                                  weertman_c = weertman_c)


#
# Melt rate model
#

# variable components
bump_amplitude      = ensemble_parameters["bump_amplitude"]
melt_rate_prefactor = ensemble_parameters["melt_rate_prefactor"]
per_century_trend   = ensemble_parameters["per_century_trend"]
random_seed         = 1

# fixed comonents

end_time = 300. # end of the simulation is 2000
bump_width = 2.5
bump_time = 245. #start simulation corresponds to 1700
trend_onset = 260. #1960
pc_max = -400.0
pc_min = -600.0 #pyclocline center limits within internal variability only
pw     = 400.0
rf_threshold = 2.0 #random forcing threshold for pc max/min

idealized_anthro_melt_rate = IdealizedAnthroMeltRate(bump_amplitude = bump_ampli
tude,
bump_width = bump_width,
bump_time = bump_time,
per_century_trend = per_century_trend,
trend_onset = trend_onset,
pc_max = pc_max,
pc_min = pc_min,
M = melt_rate_prefactor,
random_seed = random_seed,
rf_threshold = rf_threshold,
pw = pw)

#
#
#make the model
#
model = Model(grid = grid,
              bed_elevation = bathy,
              params = params,
              solver_params = solver_params,
              initial_conditions = initial_conditions,
          parallel_spec = parallel_spec,
          melt_rate = idealized_anthro_melt_rate);

initial_model = deepcopy(model) #make a deepcopy so that we can assess the initi
al vaf
update_state!(initial_model)

#
#timestepping parameters
#
niter0 = 0
dt = 0.1
#end_time = 1000.
chkpt_freq = 1000.0
pchkpt_freq = 1000.0
timestepping_params = TimesteppingParams(niter0 = niter0,
                                         dt = dt,
                                         end_time = end_time,
                                         chkpt_freq = chkpt_freq,
                                          pchkpt_freq = pchkpt_freq)

#
#output parameters
#
outputs = (h = model.fields.gh.h,
           u = model.fields.gh.u,
           v = model.fields.gh.v,
           b = model.fields.gh.b,
           s = model.fields.gh.s,
               a = model.fields.gh.accumulation,
           grfrac = model.fields.gh.grounded_fraction,
           m = model.fields.gh.basal_melt)

output_freq = 5.0
output_params = OutputParams(outputs = outputs,
                            output_freq = output_freq,
                            output_format = "mat",
                            zip_format = "nc",
                            output_start = true,
		            output_path = member_path)

#
# assemble the simulation
#
simulation = Simulation(model = model,
                        timestepping_params = timestepping_params,
                        output_params = output_params)

#
#perform the simulation
#
run_simulation!(simulation)


#
# compute the associated slr
#
initial_h = initial_model.fields.gh.h
initial_gr = initial_model.fields.gh.grounded_fraction
bed = initial_model.fields.gh.b
float_thick = abs.(1028/918 .* bed)
dh = initial_h .- float_thick
idx = initial_h .> float_thick
dh[.!(idx)] .= 0
initial_vaf = sum(sum(dh))*dx*dy

final_h = simulation.model.fields.gh.h
final_gr = simulation.model.fields.gh.grounded_fraction
dh =  final_h .- float_thick
idx = final_h .> float_thick
dh[.!(idx)] .= 0
final_vaf = sum(sum(dh))*dx*dy

dvaf = initial_vaf - final_vaf
slr = dvaf / 395/ 1e9

return slr

end
    
