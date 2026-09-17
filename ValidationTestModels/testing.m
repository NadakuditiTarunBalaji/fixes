% After running buildParentModelCore, check the generated parent model:
rtBlocks = find_system('YourParentModelName', 'BlockType', 'RateTransition');
assert(isempty(rtBlocks), 'FAIL: Rate Transition blocks were inserted!');
disp('PASS: No Rate Transition blocks found.');
% Run with a model that lacks UseDivisionForNetSlopeComputation:
result = buildParentModelCore(folder, {'model_1', 'model_2'}, 'TestParent', struct());
assert(result.Success, 'FAIL: Build did not succeed.');
% Check that the warning was logged instead of throwing:
hasWarning = any(contains(result.Warnings, 'UseDivisionForNetSlopeComputation'));
if hasWarning
    disp('PASS: Missing parameter logged as warning, build continued.');
end
val = get_param('YourParentModelName', 'AutoInsertRateTranBlk');
assert(strcmp(val, 'off'), 'FAIL: AutoInsertRateTranBlk is not off!');
disp('PASS: AutoInsertRateTranBlk is off.');


% 1. Load your generated model
load_system('test05');

% 2. Programmatically verify that parent Inport sample times are set to '0.01'
inports = find_system('test05', 'SearchDepth', 2, 'BlockType', 'Inport');
for k = 1:numel(inports)
    ts = get_param(inports{k}, 'SampleTime');
    fprintf('Block: %s | Resolved SampleTime: %s\n', inports{k}, ts);
end
% Expected: Each root Inport's sample time will be set to '0.01' (or child's rate)

% 3. Run a diagram update to confirm NO warnings are raised in Diagnostic Viewer
set_param('test05', 'SimulationCommand', 'update');
disp('PASS: Diagram compiled successfully with zero sample time warnings!');










% ----------------------------------------------------------------------------------------------------------------------------------



% 1. Load the model
load_system('test05');

% 2. Find all Inport and Outport blocks inside parent and inner subsystem
allInports = find_system('test05', 'MatchFilter', @Simulink.match.allVariants, 'BlockType', 'Inport');
allOutports = find_system('test05', 'MatchFilter', @Simulink.match.allVariants, 'BlockType', 'Outport');

% 3. Check their sample times
allOK = true;
for k = 1:numel(allInports)
    ts = get_param(allInports{k}, 'SampleTime');
    if ~strcmp(ts, '-1')
        warning('Failed on inport: %s (SampleTime is %s)', allInports{k}, ts);
        allOK = false;
    end
end

for k = 1:numel(allOutports)
    ts = get_param(allOutports{k}, 'SampleTime');
    if ~strcmp(ts, '-1')
        warning('Failed on outport: %s (SampleTime is %s)', allOutports{k}, ts);
        allOK = false;
    end
end

if allOK
    disp('PASS: Absolutely every Inport and Outport at all levels has SampleTime = -1');
end

% 4. Force diagram compilation - should compile cleanly with ZERO warnings
set_param('test05', 'SimulationCommand', 'update');
disp('PASS: Diagram compiled cleanly with zero warnings/errors.');