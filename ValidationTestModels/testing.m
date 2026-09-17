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