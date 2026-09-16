%% generate_test_slx_models.m
%
% Generates 6 Simulink test models with:
%   - Subsystems
%   - Different numbers of Inports/Outports
%   - Arithmetic / logical operations
%   - Some subsystems with no inputs
%   - Some subsystems with no outputs
%   - Intentional sample-time mismatches
%
% Output:
%   test_model_01.slx
%   test_model_02.slx
%   ...
%   test_model_06.slx
%
% Requires Simulink.

clear;
clc;

outDir = fullfile(pwd, 'generated_test_models');

if ~exist(outDir, 'dir')
    mkdir(outDir);
end

fprintf('Generating test models in:\n%s\n\n', outDir);

%% ------------------------------------------------------------------------
% Model 1: Simple arithmetic subsystem
% 2 inputs -> Sum -> Gain -> 1 output
% -------------------------------------------------------------------------

modelName = 'test_model_01';
new_system(modelName);
open_system(modelName);

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/ArithmeticSubsystem'], ...
    'Position', [250 100 500 300]);

sub = [modelName '/ArithmeticSubsystem'];

open_system(sub);

add_block('simulink/Ports & Subsystems/In1', ...
    [sub '/In1'], ...
    'Position', [30 60 60 75]);

add_block('simulink/Ports & Subsystems/In2', ...
    [sub '/In2'], ...
    'Position', [30 150 60 165]);

add_block('simulink/Math Operations/Sum', ...
    [sub '/Sum'], ...
    'Inputs', '++', ...
    'Position', [110 85 140 140]);

add_block('simulink/Math Operations/Gain', ...
    [sub '/Gain'], ...
    'Gain', '2.5', ...
    'Position', [180 95 240 130]);

add_block('simulink/Ports & Subsystems/Out1', ...
    [sub '/Out1'], ...
    'Position', [300 105 330 120]);

add_line(sub, 'In1/1', 'Sum/1');
add_line(sub, 'In2/1', 'Sum/2');
add_line(sub, 'Sum/1', 'Gain/1');
add_line(sub, 'Gain/1', 'Out1/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Model 2: Multiple operations
% 3 inputs -> Product -> Sum -> Saturation -> output
% -------------------------------------------------------------------------

modelName = 'test_model_02';
new_system(modelName);
open_system(modelName);

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/MultiOperationSubsystem'], ...
    'Position', [200 100 550 350]);

sub = [modelName '/MultiOperationSubsystem'];

open_system(sub);

add_block('simulink/Ports & Subsystems/In1', ...
    [sub '/In1'], 'Position', [30 40 60 55]);

add_block('simulink/Ports & Subsystems/In2', ...
    [sub '/In2'], 'Position', [30 100 60 115]);

add_block('simulink/Ports & Subsystems/In3', ...
    [sub '/In3'], 'Position', [30 160 60 175]);

add_block('simulink/Math Operations/Product', ...
    [sub '/Product'], ...
    'Inputs', '**', ...
    'Position', [100 60 140 140]);

add_block('simulink/Math Operations/Sum', ...
    [sub '/Sum'], ...
    'Inputs', '++', ...
    'Position', [180 80 210 130]);

add_block('simulink/Discontinuities/Saturation', ...
    [sub '/Saturation'], ...
    'UpperLimit', '100', ...
    'LowerLimit', '-100', ...
    'Position', [250 85 320 125]);

add_block('simulink/Ports & Subsystems/Out1', ...
    [sub '/Out1'], ...
    'Position', [370 100 400 115]);

add_line(sub, 'In1/1', 'Product/1');
add_line(sub, 'In2/1', 'Product/2');
add_line(sub, 'Product/1', 'Sum/1');
add_line(sub, 'In3/1', 'Sum/2');
add_line(sub, 'Sum/1', 'Saturation/1');
add_line(sub, 'Saturation/1', 'Out1/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Model 3: No input subsystem
% Constant -> Gain -> output
% -------------------------------------------------------------------------

modelName = 'test_model_03';
new_system(modelName);
open_system(modelName);

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/NoInputSubsystem'], ...
    'Position', [250 100 500 300]);

sub = [modelName '/NoInputSubsystem'];

open_system(sub);

add_block('simulink/Sources/Constant', ...
    [sub '/Constant'], ...
    'Value', '42', ...
    'Position', [50 100 100 130]);

add_block('simulink/Math Operations/Gain', ...
    [sub '/Gain'], ...
    'Gain', '3', ...
    'Position', [150 100 210 130]);

add_block('simulink/Ports & Subsystems/Out1', ...
    [sub '/Out1'], ...
    'Position', [270 105 300 120]);

add_line(sub, 'Constant/1', 'Gain/1');
add_line(sub, 'Gain/1', 'Out1/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Model 4: Input but no output
% Input -> Gain -> Terminator
% -------------------------------------------------------------------------

modelName = 'test_model_04';
new_system(modelName);
open_system(modelName);

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/NoOutputSubsystem'], ...
    'Position', [250 100 500 300]);

sub = [modelName '/NoOutputSubsystem'];

open_system(sub);

add_block('simulink/Ports & Subsystems/In1', ...
    [sub '/In1'], ...
    'Position', [40 100 70 115]);

add_block('simulink/Math Operations/Gain', ...
    [sub '/Gain'], ...
    'Gain', '10', ...
    'Position', [120 90 180 125]);

add_block('simulink/Sinks/Terminator', ...
    [sub '/Terminator'], ...
    'Position', [250 95 280 125]);

add_line(sub, 'In1/1', 'Gain/1');
add_line(sub, 'Gain/1', 'Terminator/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Model 5: Intentional sample-time mismatch
%
% In1: discrete sample time = 0.1
% In2: discrete sample time = 0.2
%
% Sum combines signals with different sample times.
% -------------------------------------------------------------------------

modelName = 'test_model_05';
new_system(modelName);
open_system(modelName);

% Configure model
set_param(modelName, ...
    'SolverType', 'Fixed-step', ...
    'Solver', 'FixedStepDiscrete', ...
    'FixedStep', '0.1');

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/SampleTimeMismatchSubsystem'], ...
    'Position', [200 100 600 350]);

sub = [modelName '/SampleTimeMismatchSubsystem'];

open_system(sub);

% First input: Ts = 0.1
add_block('simulink/Ports & Subsystems/In1', ...
    [sub '/FastInput'], ...
    'Position', [30 60 60 75], ...
    'SampleTime', '0.1');

% Second input: Ts = 0.2
add_block('simulink/Ports & Subsystems/In2', ...
    [sub '/SlowInput'], ...
    'Position', [30 160 60 175], ...
    'SampleTime', '0.2');

add_block('simulink/Math Operations/Sum', ...
    [sub '/SumMismatch'], ...
    'Inputs', '++', ...
    'Position', [130 85 160 145]);

add_block('simulink/Discrete/Unit Delay', ...
    [sub '/UnitDelay'], ...
    'SampleTime', '0.1', ...
    'Position', [210 95 260 135]);

add_block('simulink/Ports & Subsystems/Out1', ...
    [sub '/Out1'], ...
    'Position', [320 105 350 120]);

add_line(sub, 'FastInput/1', 'SumMismatch/1');
add_line(sub, 'SlowInput/1', 'SumMismatch/2');
add_line(sub, 'SumMismatch/1', 'UnitDelay/1');
add_line(sub, 'UnitDelay/1', 'Out1/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Model 6: Several sample-time mismatches and multiple outputs
%
% Input 1 : Ts = 0.1
% Input 2 : Ts = 0.5
% Input 3 : Ts = inherited
%
% Produces 2 outputs.
% -------------------------------------------------------------------------

modelName = 'test_model_06';
new_system(modelName);
open_system(modelName);

set_param(modelName, ...
    'SolverType', 'Fixed-step', ...
    'Solver', 'FixedStepDiscrete', ...
    'FixedStep', '0.1');

add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/ComplexSampleTimeSubsystem'], ...
    'Position', [200 80 650 400]);

sub = [modelName '/ComplexSampleTimeSubsystem'];

open_system(sub);

add_block('simulink/Ports & Subsystems/In1', ...
    [sub '/Input_0p1'], ...
    'Position', [30 50 60 65], ...
    'SampleTime', '0.1');

add_block('simulink/Ports & Subsystems/In2', ...
    [sub '/Input_0p5'], ...
    'Position', [30 130 60 145], ...
    'SampleTime', '0.5');

add_block('simulink/Ports & Subsystems/In3', ...
    [sub '/Input_Inherited'], ...
    'Position', [30 210 60 225]);

% Branch 1
add_block('simulink/Math Operations/Sum', ...
    [sub '/Sum1'], ...
    'Inputs', '++', ...
    'Position', [110 70 140 120]);

add_block('simulink/Math Operations/Gain', ...
    [sub '/Gain1'], ...
    'Gain', '5', ...
    'Position', [180 75 240 110]);

% Branch 2
add_block('simulink/Math Operations/Product', ...
    [sub '/Product1'], ...
    'Inputs', '**', ...
    'Position', [110 170 150 220]);

add_block('simulink/Math Operations/Abs', ...
    [sub '/Abs'], ...
    'Position', [190 175 240 215]);

% Output 1
add_block('simulink/Ports & Subsystems/Out1', ...
    [sub '/Out1'], ...
    'Position', [300 80 330 95]);

% Output 2
add_block('simulink/Ports & Subsystems/Out2', ...
    [sub '/Out2'], ...
    'Position', [300 185 330 200]);

add_line(sub, 'Input_0p1/1', 'Sum1/1');
add_line(sub, 'Input_0p5/1', 'Sum1/2');
add_line(sub, 'Sum1/1', 'Gain1/1');
add_line(sub, 'Gain1/1', 'Out1/1');

add_line(sub, 'Input_0p5/1', 'Product1/1');
add_line(sub, 'Input_Inherited/1', 'Product1/2');
add_line(sub, 'Product1/1', 'Abs/1');
add_line(sub, 'Abs/1', 'Out2/1');

close_system(sub);

save_system(modelName, fullfile(outDir, [modelName '.slx']));
close_system(modelName);


%% ------------------------------------------------------------------------
% Summary
% -------------------------------------------------------------------------

fprintf('============================================\n');
fprintf('Test model generation completed.\n');
fprintf('============================================\n\n');

for k = 1:6
    fprintf('Created: test_model_%02d.slx\n', k);
end

fprintf('\nLocation:\n%s\n', outDir);

fprintf('\nTest cases included:\n');
fprintf('1. Basic arithmetic subsystem\n');
fprintf('2. Multiple inputs and operations\n');
fprintf('3. Subsystem with no Inports\n');
fprintf('4. Subsystem with no Outports\n');
fprintf('5. Intentional sample-time mismatch\n');
fprintf('6. Multiple sample-time mismatch scenarios\n');
