#
# Copyright (c) 2021 Tobias Thummerer, Lars Mikelsons
# Licensed under the MIT license. See LICENSE file in the project root for details.
#

using Flux, DiffEqFlux
using DiffEqCallbacks
using Interpolations: interpolate, LinearInterpolation

using DiffEqFlux: ODEFunction, basic_tgrad, ODEProblem, ZygoteVJP, InterpolatingAdjoint, solve

import ForwardDiff
import Optim
import ProgressMeter

import SciMLBase: RightRootFind, CallbackSet, u_modified!, set_u!, terminate!
import SciMLBase: ContinuousCallback, VectorContinuousCallback

using FMIImport: fmi2ComponentState, fmi2ComponentStateInstantiated, fmi2ComponentStateInitializationMode, fmi2ComponentStateEventMode, fmi2ComponentStateContinuousTimeMode, fmi2ComponentStateTerminated, fmi2ComponentStateError, fmi2ComponentStateFatal
import ChainRulesCore: ignore_derivatives

using FMIImport: fmi2StatusOK, FMU2Solution, FMU2Event, fmi2Type, fmi2TypeCoSimulation, fmi2TypeModelExchange, FMU2Component
using FMIImport: logInfo, logWarn, logError

import FMIImport: undual, isdual, fd_eltypes, assert_integrator_valid, fd_set!
import FMIImport: prepareSolveFMU, finishSolveFMU, handleEvents

"""
The mutable struct representing an abstract (simulation mode unknown) NeuralFMU.
"""
abstract type NeuralFMU end

"""
Structure definition for a NeuralFMU, that runs in mode `Model Exchange` (ME).
"""
mutable struct ME_NeuralFMU <: NeuralFMU
    neuralODE::NeuralODE
    fmu::FMU

    currentComponent::Union{FMU2Component, Nothing}
    
    tspan
    saveat
    saved_values
    recordValues

    valueStack
    solution::FMU2Solution

    customCallbacksBefore::Array
    callbacks::Array
    customCallbacksAfter::Array

    x0::Array{Float64}
    firstRun::Bool
    
    tolerance::Union{Real, Nothing}
    parameters::Union{Dict{<:Any, <:Any}, Nothing}
    setup::Union{Bool, Nothing}
    reset::Union{Bool, Nothing}
    instantiate::Union{Bool, Nothing}
    freeInstance::Union{Bool, Nothing}
    terminate::Union{Bool, Nothing}

    modifiedState::Bool

    startState 
    stopState
    startEventInfo
    stopEventInfo
    start_t 
    stop_t

    progressMeter
    execution_start::Real

    solveCycle::UInt

    function ME_NeuralFMU()
        inst = new()
        inst.currentComponent = nothing
        inst.progressMeter = nothing
        inst.modifiedState = true

        inst.startState = nothing 
        inst.stopState = nothing

        inst.startEventInfo = nothing 
        inst.stopEventInfo = nothing

        inst.customCallbacksBefore = []
        inst.customCallbacksAfter = []

        inst.execution_start = 0.0

        return inst 
    end
end

"""
Structure definition for a NeuralFMU, that runs in mode `Co-Simulation` (CS).
"""
mutable struct CS_NeuralFMU{F, C} <: NeuralFMU
    model
    fmu::F
    currentComponent # ::Union{C, Nothing}
    
    tspan
    saveat

    solution::FMU2Solution
   
    re # restrucure function

    function CS_NeuralFMU{F, C}() where {F, C}
        inst = new{F, C}()

        inst.currentComponent = nothing
        inst.re = nothing

        return inst
    end
end

# function prepareSolveFMU(fmu::FMU2, c::Union{Nothing, FMU2Component}, type::fmi2Type, instantiate::Union{Nothing, Bool}, freeInstance::Union{Nothing, Bool}, terminate::Union{Nothing, Bool}, reset::Union{Nothing, Bool}, setup::Union{Nothing, Bool}, parameters::Union{Dict{<:Any, <:Any}, Nothing}, t_start, t_stop, tolerance;
#     x0::Union{AbstractArray{<:Real}, Nothing}=nothing, inputs::Union{Dict{<:Any, <:Any}, Nothing}=nothing, cleanup::Bool=false)

#     ignore_derivatives() do

#         if instantiate === nothing 
#             instantiate = fmu.executionConfig.instantiate
#         end

#         if freeInstance === nothing 
#             freeInstance = fmu.executionConfig.freeInstance
#         end

#         if terminate === nothing 
#             terminate = fmu.executionConfig.terminate
#         end

#         if reset === nothing 
#             reset = fmu.executionConfig.reset 
#         end

#         if setup === nothing 
#             setup = fmu.executionConfig.setup 
#         end 

#         # instantiate (hard)
#         if instantiate
#             # remove old one if we missed it (callback)
#             if cleanup && c != nothing
#                 finishSolveFMU(fmu, c, freeInstance, terminate)
#             end

#             c = fmi2Instantiate!(fmu; type=type)
#         else # use existing instance
#             if c === nothing && length(fmu.components) > 0
#                 c = fmu.components[end]
#             else
#                 @warn "Found no FMU instance, but executionConfig doesn't force allocation. Allocating one. Use `fmi2Instantiate(fmu)` to prevent this message."
#                 c = fmi2Instantiate!(fmu; type=type)
#             end

#             # soft terminate (if necessary)
#             # if terminate
#             #     retcode = fmi2Terminate(c; soft=true)
#             #     @assert retcode == fmi2StatusOK "fmi2Simulate(...): Termination failed with return code $(retcode)."
#             # end
#         end

#         @assert c != nothing "No FMU instance available, allocate one or use `fmu.executionConfig.instantiate=true`."

#         # soft reset (if necessary)
#         if reset
#             retcode = fmi2Reset(c; soft=true)
#             @assert retcode == fmi2StatusOK "fmi2Simulate(...): Reset failed with return code $(retcode)."
#         end 

#         # setup experiment (hard)
#         if setup
#             retcode = fmi2SetupExperiment(c, t_start, t_stop; tolerance=tolerance)
#             @assert retcode == fmi2StatusOK "fmi2Simulate(...): Setting up experiment failed with return code $(retcode)."
#         end

#         # parameters
#         if parameters !== nothing
#             retcodes = fmi2Set(c, collect(keys(parameters)), collect(Base.values(parameters)); filter=setBeforeInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial parameters failed with return code $(retcode)."
#         end

#         # inputs
#         if inputs !== nothing
#             retcodes = fmi2Set(c, collect(keys(inputs)), collect(values(inputs)); filter=setBeforeInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial inputs failed with return code $(retcode)."
#         end

#         # start state
#         if x0 !== nothing
#             #retcode = fmi2SetContinuousStates(c, x0)
#             #@assert retcode == fmi2StatusOK "fmi2Simulate(...): Setting initial state failed with return code $(retcode)."
#             retcodes = fmi2Set(c, fmu.modelDescription.stateValueReferences, x0; filter=setBeforeInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial inputs failed with return code $(retcode)."
#         end

#         # enter (hard)
#         if setup
#             retcode = fmi2EnterInitializationMode(c)
#             @assert retcode == fmi2StatusOK "fmi2Simulate(...): Entering initialization mode failed with return code $(retcode)."
#         end

#         # parameters
#         if parameters !== nothing
#             retcodes = fmi2Set(c, collect(keys(parameters)), collect(Base.values(parameters)); filter=setInInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial parameters failed with return code $(retcode)."
#         end

#         # inputs
#         if inputs !== nothing
#             retcodes = fmi2Set(c, collect(keys(inputs)), collect(Base.values(inputs)); filter=setInInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial inputs failed with return code $(retcode)."
#         end

#         # start state
#         if x0 !== nothing
#             #retcode = fmi2SetContinuousStates(c, x0)
#             #@assert retcode == fmi2StatusOK "fmi2Simulate(...): Setting initial state failed with return code $(retcode)."
#             retcodes = fmi2Set(c, fmu.modelDescription.stateValueReferences, x0; filter=setInInitialization)
#             @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial inputs failed with return code $(retcode)."
#         end

#         # exit setup (hard)
#         if setup
#             retcode = fmi2ExitInitializationMode(c)
#             @assert retcode == fmi2StatusOK "fmi2Simulate(...): Exiting initialization mode failed with return code $(retcode)."
#         end

#         if type == fmi2TypeModelExchange
#             if x0 == nothing
#                 x0 = fmi2GetContinuousStates(c)
#             end
#         end

#         if instantiate || reset # we have a fresh instance 
#             @debug "[NEW INST]"
#             handleEvents(c) 
#         end
#     end

#     return c, x0
# end

# function prepareSolveFMU(fmu::Vector{FMU2}, c::Vector{Union{Nothing, FMU2Component}}, type::fmi2Type, instantiate::Union{Nothing, Bool}, freeInstance::Union{Nothing, Bool}, terminate::Union{Nothing, Bool}, reset::Union{Nothing, Bool}, setup::Union{Nothing, Bool}, parameters::Union{Vector{Union{Dict{<:Any, <:Any}, Nothing}}, Nothing}, t_start, t_stop, tolerance;
#     x0::Union{Vector{Union{Array{<:Real}, Nothing}}, Nothing}=nothing, initFct=nothing, cleanup::Bool=false)

#     ignore_derivatives() do
#         for i in 1:length(fmu)

#             if instantiate === nothing
#                 instantiate = fmu[i].executionConfig.instantiate
#             end

#             if freeInstance === nothing 
#                 freeInstance = fmu[i].executionConfig.freeInstance
#             end

#             if terminate === nothing 
#                 terminate = fmu[i].executionConfig.terminate
#             end

#             if reset === nothing
#                 reset = fmu[i].executionConfig.reset
#             end

#             if setup === nothing
#                 setup = fmu[i].executionConfig.setup
#             end

#             # instantiate (hard)
#             if instantiate
#                 # remove old one if we missed it (callback)
#             if cleanup && c[i] != nothing
#                 finishSolveFMU(fmu[i], c[i], freeInstance, terminate)
#             end

#                 c[i] = fmi2Instantiate!(fmu[i]; type=type)
#                 @debug "[NEW INST]"
#             else
#                 if c[i] === nothing
#                     c[i] = fmu[i].components[end]
#                 end
#             end

#             # soft terminate (if necessary)
#             if terminate
#                 retcode = fmi2Terminate(c[i]; soft=true)
#                 @assert retcode == fmi2StatusOK "fmi2Simulate(...): Termination failed with return code $(retcode)."
#             end

#             # soft reset (if necessary)
#             if reset
#                 retcode = fmi2Reset(c[i]; soft=true)
#                 @assert retcode == fmi2StatusOK "fmi2Simulate(...): Reset failed with return code $(retcode)."
#             end

#             # enter setup (hard)
#             if setup
#                 retcode = fmi2SetupExperiment(c[i], t_start, t_stop; tolerance=tolerance)
#                 @assert retcode == fmi2StatusOK "fmi2Simulate(...): Setting up experiment failed with return code $(retcode)."

#                 retcode = fmi2EnterInitializationMode(c[i])
#                 @assert retcode == fmi2StatusOK "fmi2Simulate(...): Entering initialization mode failed with return code $(retcode)."
#             end

#             if x0 !== nothing
#                 if x0[i] !== nothing
#                     retcode = fmi2SetContinuousStates(c[i], x0[i])
#                     @assert retcode == fmi2StatusOK "fmi2Simulate(...): Setting initial state failed with return code $(retcode)."
#                 end
#             end

#             if parameters !== nothing
#                 if parameters[i] !== nothing
#                     retcodes = fmi2Set(c[i], collect(keys(parameters[i])), collect(values(parameters[i])) )
#                     @assert all(retcodes .== fmi2StatusOK) "fmi2Simulate(...): Setting initial parameters failed with return code $(retcode)."
#                 end
#             end

#             if initFct !== nothing
#                 initFct()
#             end

#             # exit setup (hard)
#             if setup
#                 retcode = fmi2ExitInitializationMode(c[i])
#                 @assert retcode == fmi2StatusOK "fmi2Simulate(...): Exiting initialization mode failed with return code $(retcode)."
#             end

#             if type == fmi2TypeModelExchange
#                 if x0 === nothing
#                     if x0[i] === nothing
#                         x0[i] = fmi2GetContinuousStates(c[i])
#                     end
#                 end
#             end
#         end


#     end # ignore_derivatives

#     return c, x0
# end

##### EVENT HANDLING START

function startCallback(integrator, nfmu, t)
    ignore_derivatives() do
        nfmu.solveCycle += 1
        @debug "[$(nfmu.solveCycle)][FIRST STEP]"

        nfmu.execution_start = time()

        t = undual(t)

        @assert t == nfmu.tspan[1] "startCallback(...): Called for non-start-point t=$(t)"
        
        nfmu.currentComponent, nfmu.x0 = prepareSolveFMU(nfmu.fmu, nfmu.currentComponent, fmi2TypeModelExchange, nfmu.instantiate, nfmu.freeInstance, nfmu.terminate, nfmu.reset, nfmu.setup, nfmu.parameters, nfmu.tspan[1], nfmu.tspan[end], nfmu.tolerance; x0=nfmu.x0, handleEvents=FMIFlux.handleEvents)
        
        if nfmu.currentComponent.eventInfo.nextEventTime == t && nfmu.currentComponent.eventInfo.nextEventTimeDefined == fmi2True
            @debug "Initial time event detected!"
        else
            @debug "No initial time events ..."
        end

        #@assert fmi2EnterContinuousTimeMode(nfmu.currentComponent) == fmi2StatusOK
    end
end

function stopCallback(nfmu, t)

    ignore_derivatives() do
        @debug "[$(nfmu.solveCycle)][LAST STEP]"

        t = undual(t)

        @assert t == nfmu.tspan[end] "stopCallback(...): Called for non-start-point t=$(t)"

        nfmu.currentComponent = finishSolveFMU(nfmu.fmu, nfmu.currentComponent, nfmu.freeInstance, nfmu.terminate)
        
    end
end

# Read next time event from fmu and provide it to the integrator 
function time_choice(nfmu, integrator, tStart, tStop)

    @debug assert_integrator_valid()

    # last call may be after simulation end
    if nfmu.currentComponent == nothing
        return nothing
    end

    if !nfmu.fmu.executionConfig.handleTimeEvents
        return nothing
    end

    if nfmu.currentComponent.eventInfo.nextEventTimeDefined == fmi2True
        #@debug "time_choice(...): $(nfmu.currentComponent.eventInfo.nextEventTime) at t=$(ForwardDiff.value(integrator.t))"

        if nfmu.currentComponent.eventInfo.nextEventTime >= tStart && nfmu.currentComponent.eventInfo.nextEventTime <= tStop
            #@assert sizeof(integrator.t) == sizeof(nfmu.currentComponent.eventInfo.nextEventTime) "The NeuralFMU/solver are initialized in $(sizeof(integrator.t))-bit-mode, but FMU events are defined in $(sizeof(nfmu.currentComponent.eventInfo.nextEventTime))-bit. Please define your ANN in $(sizeof(nfmu.currentComponent.eventInfo.nextEventTime))-bit mode."
            @debug "time_choice(...): At $(integrator.t) next time event announced @$(nfmu.currentComponent.eventInfo.nextEventTime)s"
            return nfmu.currentComponent.eventInfo.nextEventTime
        else
            # the time event is outside the simulation range!
            @debug "Next time event @$(nfmu.currentComponent.eventInfo.nextEventTime)s is outside simulation time range ($(tStart), $(tStop)), skipping."
            return nothing 
        end
    else
        #@debug "time_choice(...): nothing at t=$(ForwardDiff.value(integrator.t))"
        return nothing
    end

    
end

# Returns the event indicators for an FMU.
function condition(nfmu::ME_NeuralFMU, out::SubArray{<:ForwardDiff.Dual{T, V, N}, A, B, C, D}, _x, t, integrator) where {T, V, N, A, B, C, D} # Event when event_f(u,t) == 0
    
    @debug assert_integrator_valid()

    @assert nfmu.fmu.components[end].state == fmi2ComponentStateContinuousTimeMode "condition(...): Must be called in mode continuous time."

    # ToDo: set inputs here
    #fmiSetReal(myFMU, InputRef, Value)

    t = undual(t)
    x = undual(_x)

    # ToDo: Evaluate on light-weight model (sub-model) without fmi2GetXXX or similar and the bottom ANN
    #nfmu.fmu.components[end].t = t # this will auto-set time via fx-call!
    nfmu.neuralODE.model(x) # evaluate NeuralFMU (set new states)
    fmi2SetTime(nfmu.fmu, t)

    out_tmp = zeros(nfmu.fmu.modelDescription.numberOfEventIndicators)
    fmi2GetEventIndicators!(nfmu.fmu.components[end], out_tmp)

    fd_set!(out, out_tmp)

    @debug assert_integrator_valid()

    return nothing
end
function condition(nfmu::ME_NeuralFMU, out, _x, t, integrator) # Event when event_f(u,t) == 0

    @debug assert_integrator_valid()

    @assert nfmu.fmu.components[end].state == fmi2ComponentStateContinuousTimeMode "condition(...): Must be called in mode continuous time."

    #@debug "State condition..."

    # ToDo: set inputs here
    #fmiSetReal(myFMU, InputRef, Value)

    t = undual(t)
    x = undual(_x)

    # ToDo: Evaluate on light-weight model (sub-model) without fmi2GetXXX or similar and the bottom ANN
    #nfmu.fmu.components[end].t = t # this will auto-set time via fx-call!
    nfmu.neuralODE.model(x) # evaluate NeuralFMU (set new states)
    fmi2SetTime(nfmu.fmu, t)

    fmi2GetEventIndicators!(nfmu.fmu.components[end], out)

    @debug assert_integrator_valid()

    return nothing
end

global lastIndicator = nothing
global lastIndicatorX = nothing 
global lastIndicatorT = nothing
function conditionSingle(nfmu::ME_NeuralFMU, index, _x, t, integrator) 

    @assert nfmu.fmu.components[end].state == fmi2ComponentStateContinuousTimeMode "condition(...): Must be called in mode continuous time."

    # ToDo: set inputs here
    #fmiSetReal(myFMU, InputRef, Value)

    if nfmu.fmu.executionConfig.handleEventIndicators != nothing && index ∉ nfmu.fmu.executionConfig.handleEventIndicators
        return 1.0
    end

    t = undual(t)
    x = undual(_x)

    global lastIndicator # , lastIndicatorX, lastIndicatorT

    if lastIndicator == nothing || length(lastIndicator) != nfmu.fmu.modelDescription.numberOfEventIndicators
        lastIndicator = zeros(nfmu.fmu.modelDescription.numberOfEventIndicators)
    end

    # ToDo: Input Function
    
    # ToDo: Evaluate on light-weight model (sub-model) without fmi2GetXXX or similar and the bottom ANN
    #nfmu.fmu.components[end].t = t # this will auto-set time via fx-call!
    nfmu.neuralODE.model(x) # evaluate NeuralFMU (set new states)
    fmi2SetTime(nfmu.fmu, t)

    fmi2GetEventIndicators!(nfmu.fmu.components[end], lastIndicator)
    
    return lastIndicator[index]
end

function f_optim(x, nfmu, right_x_fmu) # , idx, direction::Real)
    # propagete the new state-guess `x` through the NeuralFMU
    nfmu.neuralODE.model(x)
    #indicators = fmi2GetEventIndicators(nfmu.fmu)
    return Flux.Losses.mse(right_x_fmu, fmi2GetContinuousStates(nfmu.fmu)) # - min(-direction*indicators[idx], 0.0)
end

# Handles the upcoming events.
function affectFMU!(nfmu::ME_NeuralFMU, integrator, idx)

    @debug assert_integrator_valid()

    c = nfmu.fmu.components[end]

    @assert c.state == fmi2ComponentStateContinuousTimeMode "affectFMU!(...): Must be in continuous time mode!"

    t = undual(integrator.t)
    x = undual(integrator.u)

    # there are fx-evaluations before the event is handled, reset the FMU state to the current integrator step
    mode = c.fmu.executionConfig.force
    c.fmu.executionConfig.force = true

    nfmu.neuralODE.model(x) # evaluate NeuralFMU (set new states)
    fmi2SetTime(c, t)

    c.fmu.executionConfig.force = mode

    # if inputFunction !== nothing
    #     fmi2SetReal(c, inputValues, inputFunction(integrator.t))
    # end

    fmi2EnterEventMode(c)

    #############

    #left_x_fmu = fmi2GetContinuousStates(c)
    #fmi2SetTime(c, t)
    # Todo set inputs

    # Event found - handle it
    #@assert fmi2EnterEventMode(c) == fmi2StatusOK
    handleEvents(c)

    ignore_derivatives() do
        if idx == 0
            #@debug "affectFMU!(...): Handle time event at t=$t"
        end

        if idx > 0
            #@debug "affectFMU!(...): Handle state event at t=$t"
        end
    end

    left_x = nothing
    right_x = nothing

    if c.eventInfo.valuesOfContinuousStatesChanged == fmi2True

        left_x = x

        right_x_fmu = fmi2GetContinuousStates(c) # the new FMU state after handled events

        ignore_derivatives() do 
            #@debug "affectFMU!(_, _, $idx): NeuralFMU state event from $(left_x) (fmu: $(left_x_fmu)). Indicator [$idx]: $(indicators[idx]). Optimizing new state ..."
        end

        # ToDo: Problem-related parameterization of optimize-call
        #result = optimize(x_seek -> f_optim(x_seek, nfmu, right_x_fmu), left_x, LBFGS(); autodiff = :forward)
        #result = Optim.optimize(x_seek -> f_optim(x_seek, nfmu, right_x_fmu, idx, sign(indicators[idx])), left_x, NelderMead())
        
        # if there is an ANN above the FMU, propaget FMU state through top ANN:
        if nfmu.modifiedState == true
            result = Optim.optimize(x_seek -> f_optim(x_seek, nfmu, right_x_fmu), left_x, NelderMead())
            right_x = Optim.minimizer(result)
        else # if there is no ANN above, then:
            right_x = right_x_fmu
        end

        if isdual(integrator.u)
            T, V, N = fd_eltypes(integrator.u)

            new_x = collect(ForwardDiff.Dual{T, V, N}(V(right_x[i]), ForwardDiff.partials(integrator.u[i]))   for i in 1:length(integrator.u))
            set_u!(integrator, new_x)
            
            @debug "affectFMU!(_, _, $idx): NeuralFMU event with state change at $t. Indicator [$idx]. (ForwardDiff) "
        else
            integrator.u = right_x
            @debug "affectFMU!(_, _, $idx): NeuralFMU event with state change at $t. Indicator [$idx]."
        end
       
        u_modified!(integrator, true)
    else

        ignore_derivatives() do 
            @debug "affectFMU!(_, _, $idx): NeuralFMU event without state change at $t. Indicator [$idx]."
        end

        u_modified!(integrator, false)
    end

    if c.eventInfo.nominalsOfContinuousStatesChanged == fmi2True
        x_nom = fmi2GetNominalsOfContinuousStates(c)
    end

    ignore_derivatives() do
        if idx != -1
            e = FMU2Event(t, UInt64(idx), left_x, right_x)
            push!(nfmu.solution.events, e)
        end

        # calculates state events per second
        pt = t-nfmu.tspan[1]
        ne = 0 
        for event in nfmu.solution.events
            #if t - event.t < pt 
                if event.indicator > 0 # count only state events
                    ne += 1
                end
            #end
        end
        ratio = ne / pt
       
        if ne >= 100 && ratio > nfmu.fmu.executionConfig.maxStateEventsPerSecond
            logError(nfmu.fmu, "Event jittering detected $(round(Integer, ratio)) events/s, aborting at t=$(t) (rel. t=$(pt)) at event $(ne):")
            for i in 0:nfmu.fmu.modelDescription.numberOfEventIndicators
                num = 0
                for e in nfmu.solution.events
                    if e.indicator == i
                        num += 1 
                    end 
                end
                if num > 0
                    logError(nfmu.fmu, "\tEvent indicator #$(i) triggered $(num) ($(round(num/1000.0*100.0; digits=1))%)")
                end
            end

            terminate!(integrator)
        end
    end

    @debug assert_integrator_valid()
end

# Does one step in the simulation.
function stepCompleted(nfmu::ME_NeuralFMU, x, t, integrator, tStart, tStop)

    @debug assert_integrator_valid()

    #@debug "Step"
    # there might be no component!
    # @assert nfmu.currentComponent.state == fmi2ComponentStateContinuousTimeMode "stepCompleted(...): Must be in continuous time mode."

    if nfmu.progressMeter !== nothing
        ProgressMeter.update!(nfmu.progressMeter, floor(Integer, 1000.0*(t-tStart)/(tStop-tStart)) )
    end

    if nfmu.currentComponent != nothing
        (status, enterEventMode, terminateSimulation) = fmi2CompletedIntegratorStep(nfmu.currentComponent, fmi2True)

        if terminateSimulation == fmi2True
            logError(nfmu.fmu, "stepCompleted(...): FMU requested termination!")
        end

        if enterEventMode == fmi2True
            affectFMU!(nfmu, integrator, -1)
        else
            # ToDo: set inputs here
            #fmiSetReal(myFMU, InputRef, Value)
        end

        #@debug "Step completed at $(ForwardDiff.value(t)) with $(collect(ForwardDiff.value(xs) for xs in x))"
    end

    @debug assert_integrator_valid()
end

# save FMU values 
function saveValues(nfmu, c::FMU2Component, recordValues, _x, t, integrator)

    t = undual(t) 
    x = undual(_x)

    # ToDo: Evaluate on light-weight model (sub-model) without fmi2GetXXX or similar and the bottom ANN
    #c.t = t # this will auto-set time via fx-call!
    nfmu.neuralODE.model(x) # evaluate NeuralFMU (set new states)
    fmi2SetTime(c, t)
    
    # Todo set inputs
    
    return (fmi2GetReal(c, recordValues)...,)
end

function fx(nfmu,
    dx,#::Array{<:Real},
    x,#::Array{<:Real},
    p::Array,
    t::Real) 

    #nanx = !any(isnan.(collect(any(isnan.(ForwardDiff.partials.(x[i]).values)) for i in 1:length(x))))
    #nanu = !any(isnan(ForwardDiff.partials(t)))

    #@assert nanx && nanu "NaN in start fx nanx = $nanx   nanu = $nanu @ $(t)."
    
    dx_tmp = fx(nfmu,x,p,t)

    fd_set!(dx, dx_tmp)

    return dx
end

function fx(nfmu,
    x,#::Array{<:Real},
    p::Array,
    t::Real) 
    
    c = nfmu.currentComponent

    if c === nothing
        # this should never happen!
        return zeros(length(x))
    end

    #nfmu.fmu.components[end].t = t 
    dx = nfmu.neuralODE.re(p)(x)

    ignore_derivatives() do

        t = undual(t)
        fmi2SetTime(c, t)

        #@debug "fx($t, $(collect(ForwardDiff.value(xs) for xs in x))) = $(collect(ForwardDiff.value(xs) for xs in dx))"

        #nfmu.currentComponent.solution.evals_fx += 1
    end 

    return dx
end

##### EVENT HANDLING END

"""
Constructs a ME-NeuralFMU where the FMU is at an arbitrary location inside of the NN.

# Arguents
    - `fmu` the considered FMU inside the NN 
    - `model` the NN topology (e.g. Flux.chain)
    - `tspan` simulation time span
    - `alg` a numerical ODE solver
    - `convertParams` automatically convert ANN parameters to Float64 if not already

# Keyword arguments
    - `saveat` time points to save the NeuralFMU output, if empty, solver step size is used (may be non-equidistant)
    - `fixstep` forces fixed step integration
    - `recordFMUValues` additionally records internal FMU variables (currently not supported because of open issues)
"""
function ME_NeuralFMU(fmu::FMU2, 
                      model, 
                      tspan, 
                      alg=nothing; 
                      saveat=[], 
                      recordValues = nothing, 
                      kwargs...)

    #@assert !need_convert(Float64, model) "Model needs to be converted to Float64 in order to beeing used as ME-NeuralFMU. This can be done via [1] `model = convert(Float64, model)` or [2] by translating layer parameters to Float64 by yourself or [3] using `FMIFlux.Chain` instead of `Flux.Chain` in your code."

    nfmu = ME_NeuralFMU()

    ######

    nfmu.fmu = fmu
    
    nfmu.saved_values = nothing

    nfmu.recordValues = prepareValueReference(fmu, recordValues)

    # abstol=abstol, reltol=reltol, dtmin=dtmin, force_dtmin=force_dtmin, 
    nfmu.neuralODE = NeuralODE(model, tspan, alg; saveat=saveat, kwargs...)

    nfmu.tspan = tspan
    nfmu.saveat = saveat

    ######
    
    nfmu
end

"""
Constructs a CS-NeuralFMU where the FMU is at an arbitrary location inside of the NN.

# Arguents
    - `fmu` the considered FMU inside the NN 
    - `model` the NN topology (e.g. Flux.chain)
    - `tspan` simulation time span

# Keyword arguments
    - `saveat` time points to save the NeuralFMU output, if empty, solver step size is used (may be non-equidistant)
"""
function CS_NeuralFMU(fmu::Union{FMU2, Vector{<:FMU2}},
                      model, 
                      tspan; 
                      saveat=[], 
                      recordValues = [])

    nfmu = nothing
    if typeof(fmu) == FMU2
        nfmu = CS_NeuralFMU{FMU2, FMU2Component}()
        nfmu.currentComponent = nothing
    else
        nfmu = CS_NeuralFMU{Vector{FMU2}, Vector{FMU2Component} }()
        nfmu.currentComponent = Vector{Union{FMU2Component, Nothing}}(nothing, length(fmu))
    end

    nfmu.fmu = fmu

    nfmu.model = model # Chain(model.layers...)

    nfmu.tspan = tspan
    nfmu.saveat = saveat

    nfmu
end

# function finishSolveFMU(fmu::FMU2, c::Union{FMU2Component, Nothing}, freeInstance::Union{Nothing, Bool}, terminate::Union{Nothing, Bool}; popComponent::Bool=true)

#     # nothing to do here with `c == nothing`
#     if c == nothing 
#         return c 
#     end

#     ignore_derivatives() do
#         if terminate === nothing
#             terminate = fmu.executionConfig.terminate
#         end

#         if freeInstance === nothing
#             freeInstance = fmu.executionConfig.freeInstance
#         end

#         # soft terminate (if necessary)
#         if terminate
#             retcode = fmi2Terminate(c; soft=true)
#             @assert retcode == fmi2StatusOK "fmi2Simulate(...): Termination failed with return code $(retcode)."
#         end

#         if freeInstance
#             fmi2FreeInstance!(c; popComponent=popComponent)
#             @debug "[RELEASED INST]"
#             c = nothing
#         end

#     end # ignore_derivatives

#     return c
# end

# function finishSolveFMU(fmu::Vector{FMU2}, c::Vector{Union{FMU2Component, Nothing}}, freeInstance::Union{Nothing, Bool}, terminate::Union{Nothing, Bool})

#     ignore_derivatives() do
#         for i in 1:length(fmu)
#             if terminate === nothing
#                 terminate = fmu[i].executionConfig.terminate
#             end

#             if freeInstance === nothing
#                 freeInstance = fmu[i].executionConfig.freeInstance
#             end

#             if c[i] != nothing

#                 # soft terminate (if necessary)
#                 if terminate
#                     retcode = fmi2Terminate(c[i]; soft=true)
#                     @assert retcode == fmi2StatusOK "fmi2Simulate(...): Termination failed with return code $(retcode)."
#                 end

#                 if freeInstance
#                     fmi2FreeInstance!(c[i])
#                     @debug "[RELEASED INST]"
#                 end
#                 c[i] = nothing
#             end
#         end

#     end # ignore_derivatives

#     return c
# end

function checkExecTime(integrator, nfmu::ME_NeuralFMU, max_execution_duration::Real)
    dist = max(nfmu.execution_start + max_execution_duration - time(), 0.0)
    
    if dist <= 0.0
        logWarn(nfmu.fmu, "Reached max execution duration ($(max_execution_duration)), exiting...")
        terminate!(integrator)
    end

    return dist
end

"""
Evaluates the ME_NeuralFMU in the timespan given during construction or in a custom timespan from `t_start` to `t_stop` for a given start state `x_start`.

# Keyword arguments
    - `reset`, the FMU is reset every time evaluation is started (default=`true`).
    - `setup`, the FMU is set up every time evaluation is started (default=`true`).
"""
function (nfmu::ME_NeuralFMU)(x_start::Union{Array{<:Real}, Nothing} = nfmu.x0,
    tspan::Tuple{Float64, Float64} = nfmu.tspan;
    showProgress::Bool = false,
    progressDescr::String="Simulating ME-NeuralFMU ...",
    tolerance::Union{Real, Nothing} = nothing,
    parameters::Union{Dict{<:Any, <:Any}, Nothing} = nothing,
    setup::Union{Bool, Nothing} = nothing,
    reset::Union{Bool, Nothing} = nothing,
    instantiate::Union{Bool, Nothing} = nothing,
    freeInstance::Union{Bool, Nothing} = nothing,
    terminate::Union{Bool, Nothing} = nothing,
    p=nothing,
    saveEventPositions::Bool=false,
    max_execution_duration::Real=-1.0,
    recordValues::fmi2ValueReferenceFormat=nfmu.recordValues,
    saveat=nfmu.saveat, # ToDo: Data type 
    kwargs...)

    recordValues = prepareValueReference(nfmu.fmu, recordValues)

    saving = (length(recordValues) > 0)
    sense = nfmu.fmu.executionConfig.sensealg
    inPlace = nfmu.fmu.executionConfig.inPlace
    #tspan = getfield(nfmu.neuralODE, :tspan)

    # setup problem and parameters
    if p == nothing
        p = nfmu.neuralODE.p
    end

    t_start = tspan[1]
    t_stop = tspan[end]

    ignore_derivatives() do
        @debug "ME_NeuralFMU..."

        nfmu.firstRun = true

        nfmu.tolerance = tolerance
        nfmu.parameters = parameters
        nfmu.setup = setup
        nfmu.reset = reset
        nfmu.instantiate = instantiate
        nfmu.freeInstance = freeInstance
        nfmu.terminate = terminate
        nfmu.currentComponent = nothing
        nfmu.solveCycle = 0
        nfmu.progressMeter = nothing
        nfmu.callbacks = []

        # simulation tspan 
        
        nfmu.tspan = (t_start, t_stop)
        nfmu.x0 = x_start

        # from here on, we are in event mode, if `setup=false` this is the job of the user
        # @assert nfmu.currentComponent.state == fmi2ComponentStateEventMode "FMU needs to be in event mode after setup (end)."

        # this is not necessary for NeuralFMUs:
        #x0 = fmi2GetContinuousStates(nfmu.currentComponent)
        #x0_nom = fmi2GetNominalsOfContinuousStates(nfmu.currentComponent)

        # initial event handling
        # handleEvents(nfmu.currentComponent)
        # fmi2EnterContinuousTimeMode(nfmu.currentComponent)

        
        # OPT A
        # startcb = FunctionCallingCallback((u, t, integrator) -> startCallback(integrator, nfmu, t);
        #          funcat=[nfmu.tspan[1]], func_start=true, func_everystep=false)
        # push!(nfmu.callbacks, startcb)
        # OPT B
        startCallback(nothing, nfmu, t_start)
    end
    
    nfmu.solution = FMU2Solution(nfmu.currentComponent)

    ignore_derivatives() do
        # custom callbacks
        for cb in nfmu.customCallbacksBefore
            push!(nfmu.callbacks, cb)
        end

        nfmu.fmu.hasStateEvents = (nfmu.fmu.modelDescription.numberOfEventIndicators > 0)
        nfmu.fmu.hasTimeEvents = (nfmu.currentComponent.eventInfo.nextEventTimeDefined == fmi2True)

        # time event handling

        if nfmu.fmu.executionConfig.handleTimeEvents && nfmu.fmu.hasTimeEvents
            timeEventCb = IterativeCallback((integrator) -> time_choice(nfmu, integrator, t_start, t_stop),
            (integrator) -> affectFMU!(nfmu, integrator, 0), 
            Float64; 
            initial_affect=(nfmu.currentComponent.eventInfo.nextEventTime == t_start), # already checked in the outer closure: nfmu.currentComponent.eventInfo.nextEventTimeDefined == fmi2True
            save_positions=(saveEventPositions, saveEventPositions))

            push!(nfmu.callbacks, timeEventCb)
        end

        # state event callback

        if nfmu.fmu.hasStateEvents && nfmu.fmu.executionConfig.handleStateEvents
            if nfmu.fmu.executionConfig.useVectorCallbacks

                eventCb = VectorContinuousCallback((out, x, t, integrator) -> condition(nfmu, out, x, t, integrator),
                                                (integrator, idx) -> affectFMU!(nfmu, integrator, idx),
                                                Int64(nfmu.fmu.modelDescription.numberOfEventIndicators);
                                                rootfind=RightRootFind,
                                                save_positions=(saveEventPositions, saveEventPositions),
                                                interp_points=nfmu.fmu.executionConfig.rootSearchInterpolationPoints)
                push!(nfmu.callbacks, eventCb)
            else

                for idx in 1:nfmu.fmu.modelDescription.numberOfEventIndicators
                    eventCb = ContinuousCallback((x, t, integrator) -> conditionSingle(nfmu, idx, x, t, integrator),
                                                    (integrator) -> affectFMU!(nfmu, integrator, idx);
                                                    rootfind=RightRootFind,
                                                    save_positions=(saveEventPositions, saveEventPositions),
                                                    interp_points=nfmu.fmu.executionConfig.rootSearchInterpolationPoints)
                    push!(nfmu.callbacks, eventCb)
                end
            end
        end

        if max_execution_duration > 0.0
            terminateCb = ContinuousCallback((x, t, integrator) -> checkExecTime(integrator, nfmu, max_execution_duration),
                                                    (integrator) -> terminate!(integrator);
                                                    save_positions=(false, false))
            push!(nfmu.callbacks, terminateCb)
            #@info "Setting max execeution time to $(max_execution_duration)"
        end

        # custom callbacks
        for cb in nfmu.customCallbacksAfter
            push!(nfmu.callbacks, cb)
        end

        if showProgress
            nfmu.progressMeter = ProgressMeter.Progress(1000; desc=progressDescr, color=:blue, dt=1.0) #, barglyphs=ProgressMeter.BarGlyphs("[=> ]"))
            ProgressMeter.update!(nfmu.progressMeter, 0) # show it!
        end

        # integrator step callback
        stepCb = FunctionCallingCallback((x, t, integrator) -> stepCompleted(nfmu, x, t, integrator, t_start, t_stop);
                                            func_everystep=true,
                                            func_start=true)
        push!(nfmu.callbacks, stepCb)

        if saving
            nfmu.solution.values = SavedValues(Float64, Tuple{collect(Float64 for i in 1:length(recordValues))...})
            nfmu.solution.valueReferences = recordValues

            if nfmu.saveat === nothing
                savingCB = SavingCallback((x, t, integrator) -> saveValues(nfmu, nfmu.fmu.components[end], recordValues, x, t, integrator),
                                nfmu.solution.values)
            else
                savingCB = SavingCallback((x, t, integrator) -> saveValues(nfmu, nfmu.fmu.components[end], recordValues, x, t, integrator),
                                nfmu.solution.values,
                                saveat=saveat)
            end
            push!(nfmu.callbacks, savingCB)
        end

        # auto pick sensealg

        if sense === nothing

            p_len = length(p[1])

            # in Julia 1.6,  Callbacks only working with ForwardDiff for discontinuous systems
            if nfmu.fmu.hasStateEvents || nfmu.fmu.hasTimeEvents # p_len < 100 
                
                fds_chunk_size = p_len
                # limit to 256 because of RAM usage
                if fds_chunk_size > 256
                    fds_chunk_size = 256
                end
                if fds_chunk_size < 1
                    fds_chunk_size = 1
                end

                #sense = ForwardDiffSensitivity(;convert_tspan=true)
                sense = ForwardDiffSensitivity(;chunk_size=fds_chunk_size, convert_tspan=true) 
                #sense = QuadratureAdjoint(autojacvec=ZygoteVJP())

                if (nfmu.fmu.hasStateEvents && nfmu.fmu.executionConfig.handleStateEvents) || (nfmu.fmu.hasTimeEvents && nfmu.fmu.executionConfig.handleTimeEvents)
                    if inPlace === true
                        #logWarn(nfmu.fmu, "NeuralFMU: The configuration orders to use `inPlace=true`, but this is currently not supported by the (automatically) determined sensealg `ForwardDiff` for discontinuous NeuralFMUs. Switching to `inPlace=false`. If you don't want this behaviour, explicitely choose a sensealg instead of `nothing`.")
                        inPlace = false # ForwardDiff only works for out-of-place (currently), overwriting `dx` leads to issues like `dt < dtmin`
                    end
                end
        
            else
                sense = InterpolatingAdjoint(autojacvec=ZygoteVJP()) # EnzymeVJP()

                if inPlace === true
                    #logWarn(nfmu.fmu, "NeuralFMU: The configuration orders to use `inPlace=true`, but this is currently not supported by the (automatically) determined sensealg `Zygote`. Switching to `inPlace=false`. If you don't want this behaviour, explicitely choose a sensealg instead of `nothing`.")
                    inPlace = false # Zygote only works for out-of-place (currently)
                end
            end
        end

    end # ignore_derivatives

    prob = nothing

    if inPlace
        ff = ODEFunction{true}((dx, x, p, t) -> fx(nfmu, dx, x, p, t), 
                               tgrad=nothing)
        prob = ODEProblem{true}(ff, nfmu.x0, nfmu.tspan, p)
    else 
        ff = ODEFunction{false}((x, p, t) -> fx(nfmu, x, p, t), 
                                tgrad=nothing) # basic_tgrad)
        prob = ODEProblem{false}(ff, nfmu.x0, nfmu.tspan, p)
    end

    # if (length(nfmu.callbacks) == 2) # only start and stop callback, so the system is pure continuous
    #     startCallback(nfmu, nfmu.tspan[1])
    #     nfmu.solution.states = solve(prob, nfmu.neuralODE.args...; sensealg=sense, saveat=nfmu.saveat, nfmu.neuralODE.kwargs...)
    #     stopCallback(nfmu, nfmu.tspan[end])
    # else
    #nfmu.solution.states = solve(prob, nfmu.neuralODE.args...; sensealg=sense, saveat=nfmu.saveat, callback = CallbackSet(nfmu.callbacks...), nfmu.neuralODE.kwargs...)
    nfmu.solution.states = solve(prob, nfmu.neuralODE.args...; saveat=nfmu.saveat, callback=CallbackSet(nfmu.callbacks...), nfmu.neuralODE.kwargs..., kwargs...) 
    
    #end

    # this code is executed after the initial solve-evaluation (further ForwardDiff-solve-evaluations will happen after this!)
    ignore_derivatives() do
        
        nfmu.solution.success = (nfmu.solution.states.retcode == :Success)

    end # ignore_derivatives

    # stopCB (Opt B)
    stopCallback(nfmu, t_stop)

    return nfmu.solution
end
function (nfmu::ME_NeuralFMU)(x0::Union{Array{<:Real}, Nothing},
    t::Real;
    p=nothing)

    return fx(nfmu, x0, p, t)
end

"""
Evaluates the CS_NeuralFMU in the timespan given during construction or in a custum timespan from `t_start` to `t_stop` with a given time step size `t_step`.

Via optional argument `reset`, the FMU is reset every time evaluation is started (default=`true`).
"""
function (nfmu::CS_NeuralFMU{F, C})(inputFct,
                                 t_step::Real, 
                                 tspan::Tuple{Float64, Float64} = nfmu.tspan; 
                                 p=nothing,
                                 tolerance::Union{Real, Nothing} = nothing,
                                 parameters::Union{Dict{<:Any, <:Any}, Nothing} = nothing,
                                 setup::Union{Bool, Nothing} = nothing,
                                 reset::Union{Bool, Nothing} = nothing,
                                 instantiate::Union{Bool, Nothing} = nothing,
                                 freeInstance::Union{Bool, Nothing} = nothing,
                                 terminate::Union{Bool, Nothing} = nothing) where {F, C}

    t_start, t_stop = tspan
    nfmu.currentComponent, _ = prepareSolveFMU(nfmu.fmu, nfmu.currentComponent, fmi2TypeCoSimulation, instantiate, freeInstance, terminate, reset, setup, parameters, t_start, t_stop, tolerance; cleanup=true)
    nfmu.solution = FMU2Solution(nfmu.currentComponent)

    ts = collect(t_start:t_step:t_stop)
    nfmu.currentComponent.skipNextDoStep = true # skip first fim2DoStep-call
    model_input = inputFct.(ts)

    function simStep(input)
        y = nothing 

        if p == nothing # structured, implicite parameters
            y = nfmu.model(input)
        else # flattened, explicite parameters
            @assert nfmu.re != nothing "Using explicite parameters without destructing the model."
            
            y = nfmu.re(p)(input)
        end
        ignore_derivatives() do
            fmi2DoStep(nfmu.currentComponent, t_step)
        end
        return y
    end

    valueStack = simStep.(model_input)

    ignore_derivatives() do
        nfmu.solution.success = true
    end

    nfmu.solution.values = SavedValues{typeof(ts[1]), typeof(valueStack[1])}(ts, valueStack)

    # this is not possible in CS (pullbacks are sometimes called after the finished simulation), clean-up happens at the next call
    # nfmu.currentComponent = finishSolveFMU(nfmu.fmu, nfmu.currentComponent, freeInstance, terminate)

    #nfmu.currentComponent.solution = nfmu.solution

    return nfmu.solution
end

function (nfmu::CS_NeuralFMU{Vector{F}, Vector{C}})(inputFct,
                                         t_step::Real, 
                                         tspan::Tuple{Float64, Float64} = nfmu.tspan; 
                                         p=nothing,
                                         tolerance::Union{Real, Nothing} = nothing,
                                         parameters::Union{Vector{Union{Dict{<:Any, <:Any}, Nothing}}, Nothing} = nothing,
                                         setup::Union{Bool, Nothing} = nothing,
                                         reset::Union{Bool, Nothing} = nothing,
                                         instantiate::Union{Bool, Nothing} = nothing,
                                         freeInstance::Union{Bool, Nothing} = nothing,
                                         terminate::Union{Bool, Nothing} = nothing) where {F, C}

    t_start, t_stop = tspan
    nfmu.currentComponent, _ = prepareSolveFMU(nfmu.fmu, nfmu.currentComponent, fmi2TypeCoSimulation, instantiate, freeInstance, terminate, reset, setup, parameters, t_start, t_stop, tolerance; cleanup=true)
    nfmu.solution = FMU2Solution(nfmu.currentComponent)

    ts = collect(t_start:t_step:t_stop)
    for c in nfmu.currentComponent
        c.skipNextDoStep = true
    end
    model_input = inputFct.(ts)

    function simStep(input)
        y = nothing

        if p == nothing # structured, implicite parameters
            y = nfmu.model(input)
        else # flattened, explicite parameters
            @assert nfmu.re != nothing "Using explicite parameters without destructing the model."
            #_p = collect(ForwardDiff.value(r) for r in p[1])
            if length(p) == 1
                y = nfmu.re(p[1])(input)
            else
                y = nfmu.re(p)(input)
            end
        end

        ignore_derivatives() do
            for c in nfmu.currentComponent
                fmi2DoStep(c, t_step)
            end
        end
        return y
    end

    valueStack = simStep.(model_input)

    ignore_derivatives() do
        nfmu.solution.success = true
    end 
    
    nfmu.solution.values = SavedValues{typeof(ts[1]), typeof(valueStack[1])}(ts, valueStack)
    
    #nfmu.currentComponent.solution = nfmu.solution

    # this is not possible in CS (pullbacks are sometimes called after the finished simulation), clean-up happens at the next call
    # nfmu.currentComponent = finishSolveFMU(nfmu.fmu, nfmu.currentComponent, freeInstance, terminate)

    return nfmu.solution
end

# adapting the Flux functions
function Flux.params(nfmu::ME_NeuralFMU; destructure::Bool=false)
    if destructure 
        p, nfmu.re = Flux.destructure(nfmu.neuralODE)
        return p
    else
        return Flux.params(nfmu.neuralODE)
    end
end

function Flux.params(nfmu::CS_NeuralFMU; destructure::Bool=true)
    if destructure 
        p, nfmu.re = Flux.destructure(nfmu.model)
        return Flux.params([p])
    else
        return Flux.params(nfmu.model)
    end
end

# FMI version independent dosteps

# function ChainRulesCore.rrule(f::Union{typeof(fmi2SetupExperiment), 
#                                        typeof(fmi2EnterInitializationMode), 
#                                        typeof(fmi2ExitInitializationMode),
#                                        typeof(fmi2Reset),
#                                        typeof(fmi2Terminate)}, args...)

#     y = f(args...)

#     function pullback(ȳ)
#         return collect(ZeroTangent() for arg in args)
#     end

#     return y, fmi2EvaluateME_pullback
# end

"""

    train!(loss, params::Union{Flux.Params, Zygote.Params}, data, optim::Flux.Optimise.AbstractOptimiser; gradient::Symbol=:Zygote, cb=nothing, chunk_size::Integer=64, printStep::Bool=false)

A function analogous to Flux.train! but with additional features and explicit parameters (faster).

# Arguments
- `loss` a loss function in the format `loss(p)`
- `params` a object holding the parameters
- `data` the training data (or often an iterator)
- `optim` the optimizer used for training 

# Keywords 
- `gradient` a symbol determining the AD-library for gradient computation, available are `:ForwardDiff` (default) and `:Zygote`
- `cb` a custom callback function that is called after every training step
- `chunk_size` the chunk size for AD using ForwardDiff (ignored for other AD-algorithms)
- `printStep` a boolean determining wheater the gradient min/max is printed after every step (for gradient debugging)
"""
function train!(loss, params::Union{Flux.Params, Zygote.Params, Vector{Vector{Float32}}}, data, optim::Flux.Optimise.AbstractOptimiser; gradient::Symbol=:ForwardDiff, cb=nothing, chunk_size::Union{Integer, Nothing}=nothing, printStep::Bool=false, proceed_on_assert::Bool=false)

    to_differentiate = p -> loss(p)

    if VERSION < v"1.7.0"
        @warn "Training under Julia 1.6 is very slow, please consider using Julia 1.7 or newer."
    end

    for i in 1:length(data)

        try
            
            for j in 1:length(params)

                if gradient == :ForwardDiff

                    if chunk_size == nothing
                        
                        # chunk size heuristics: as large as the RAM allows it (estimate)
                        # for some reason, Julia 1.6 can't handle large chunks (enormous compilation time), this is not an issue with Julia >= 1.7
                        if VERSION >= v"1.7.0"
                            chunk_size = ceil(Int, sqrt( Sys.total_memory()/(2^30) ))*32
                            
                        else
                            chunk_size = ceil(Int, sqrt( Sys.total_memory()/(2^30) ))*4
                            #grad = ForwardDiff.gradient(to_differentiate, params[j]);
                        end

                        grad_conf = ForwardDiff.GradientConfig(to_differentiate, params[j], ForwardDiff.Chunk{min(chunk_size, length(params[j]))}());
                        grad = ForwardDiff.gradient(to_differentiate, params[j], grad_conf);

                    else
                        grad_conf = ForwardDiff.GradientConfig(to_differentiate, params[j], ForwardDiff.Chunk{min(chunk_size, length(params[j]))}());
                        grad = ForwardDiff.gradient(to_differentiate, params[j], grad_conf);
                    end

                elseif gradient == :Zygote 
                    grad = Zygote.gradient(
                        to_differentiate,
                        params[j])[1]
                else
                    @assert false "Unknown `gradient=$(gradient)`, supported are `:ForwardDiff` and `:Zygote`."
                end

                step = Flux.Optimise.apply!(optim, params[j], grad)
                params[j] .-= step

                if printStep
                    @info "Grad: Min = $(min(abs.(grad)...))   Max = $(max(abs.(grad)...))"
                    @info "Step: Min = $(min(abs.(step)...))   Max = $(max(abs.(step)...))"
                end
            end    

        catch e

            if proceed_on_assert
                @error "Training asserted, but continuing: $e"
            else
                throw(e)
            end
        end
        
        if cb != nothing 
            if isa(cb, AbstractArray)
                for _cb in cb 
                    _cb()
                end
            else
                cb()
            end
        end
    end
end

function train!(loss, neuralFMU::ME_NeuralFMU, data, optim::Flux.Optimise.AbstractOptimiser; kwargs...)
    params = Flux.params(neuralFMU)   
    train!(loss, params, data, optim; kwargs...)
end