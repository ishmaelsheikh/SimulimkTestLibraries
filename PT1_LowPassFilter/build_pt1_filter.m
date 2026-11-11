%% build_pt1_filter.m
% Builds PT1_Filter_Demo.slx:
%   - Masked subsystem "PT1_Filter" with 3 inputs (u, reset, T_filt) and 1 output (y)
%   - Test harness: noisy step input, reset pulse, constant filter time,
%     plus a 1st-order FIR (2-tap moving average) for comparison.
%
% Discrete PT1 law (forward Euler, task time Ts):
%   y[k] = (u[k] - y[k-1]) * (Ts / T_filt) + y[k-1]
%   K = Ts / max(T_filt, Ts)     (T_filt <= Ts -> K = 1, pass-through;
%                                 avoids divide-by-zero and K > 1 instability)
%   reset = 1  ->  y[k] = u[k]   (output re-initialised to the input)

mdl = 'PT1_Filter_Demo';
if bdIsLoaded(mdl), close_system(mdl, 0); end
if exist([mdl '.slx'], 'file'), delete([mdl '.slx']); end
new_system(mdl);
open_system(mdl);

% Task time used by the harness / solver
Ts_task = 0.001; %#ok<NASGU>
set_param(mdl, 'PreLoadFcn', 'Ts_task = 0.001;', ...
               'InitFcn',    'if ~exist(''Ts_task'',''var''), Ts_task = 0.001; end', ...
               'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
               'FixedStep', 'Ts_task', 'StopTime', '5');
evalin('base', 'Ts_task = 0.001;');

%% ---------------- PT1_Filter subsystem ----------------
sub = [mdl '/PT1_Filter'];
add_block('built-in/Subsystem', sub, 'Position', [330 95 450 205]);

p = @(x, y, w, h) [x y x+w y+h];   % position helper

add_block('simulink/Sources/In1',  [sub '/u'],      'Position', p(30,  40, 30, 14), 'Port', '1');
add_block('simulink/Sources/In1',  [sub '/reset'],  'Position', p(30, 300, 30, 14), 'Port', '2');
add_block('simulink/Sources/In1',  [sub '/T_filt'], 'Position', p(30, 160, 30, 14), 'Port', '3');
add_block('simulink/Sinks/Out1',   [sub '/y'],      'Position', p(820, 115, 30, 14));

% --- gain calculation: K = Ts / max(T_filt, Ts)  (K <= 1, no divide-by-zero) ---
add_block('simulink/Sources/Constant', [sub '/Ts'], 'Value', 'Ts', ...
          'Position', p(30, 205, 40, 26));
add_block('simulink/Math Operations/MinMax', [sub '/T_ge_Ts'], 'Function', 'max', ...
          'Inputs', '2', 'Position', p(130, 160, 35, 50));
add_block('simulink/Math Operations/Divide', [sub '/Ts_div_T'], 'Inputs', '*/', ...
          'Position', p(250, 160, 35, 50));

% --- filter core ---
add_block('simulink/Math Operations/Sum', [sub '/Err'], 'Inputs', '+-', ...
          'IconShape', 'round', 'Position', p(250, 40, 25, 25));
add_block('simulink/Math Operations/Product', [sub '/K_x_Err'], ...
          'Position', p(400, 45, 35, 50));
add_block('simulink/Math Operations/Sum', [sub '/Integrate'], 'Inputs', '++', ...
          'IconShape', 'round', 'Position', p(490, 57, 25, 25));
add_block('simulink/Signal Routing/Switch', [sub '/Reset_Switch'], ...
          'Criteria', 'u2 ~= 0', 'Position', p(640, 100, 40, 60));
add_block('simulink/Discrete/Unit Delay', [sub '/y_prev'], ...
          'InitialCondition', 'y0', 'SampleTime', '-1', ...
          'Orientation', 'left', 'Position', p(560, 240, 35, 35));

% --- wiring ---
L = @(a, b) add_line(sub, a, b, 'autorouting', 'on');
L('T_filt/1',   'T_ge_Ts/1');
L('Ts/1',       'T_ge_Ts/2');
L('Ts/1',       'Ts_div_T/1');
L('T_ge_Ts/1',  'Ts_div_T/2');
L('Ts_div_T/1', 'K_x_Err/2');

L('u/1',        'Err/1');
L('y_prev/1',   'Err/2');
L('Err/1',      'K_x_Err/1');
L('K_x_Err/1',  'Integrate/1');
L('y_prev/1',   'Integrate/2');

L('u/1',        'Reset_Switch/1');   % reset active   -> y = u
L('reset/1',    'Reset_Switch/2');
L('Integrate/1','Reset_Switch/3');   % reset inactive -> filtered value
L('Reset_Switch/1', 'y/1');
L('Reset_Switch/1', 'y_prev/1');

% --- mask: task time and initial output ---
m = Simulink.Mask.create(sub);
m.Type = 'PT1 Filter';
m.Description = ['Discrete 1st-order low pass: y = y_prev + K*(u - y_prev), ' ...
                 'K = Ts/max(T_filt, Ts). reset~=0 sets y = u.'];
m.addParameter('Name', 'Ts', 'Prompt', 'Task time Ts [s]', 'Value', 'Ts_task');
m.addParameter('Name', 'y0', 'Prompt', 'Initial output y0', 'Value', '0');
m.Display = 'disp(''PT1'')';

%% ---------------- Test harness ----------------
% Input: step 0 -> 1 at t = 0.5 s, plus 50 Hz noise (amp 0.2)
add_block('simulink/Sources/Step', [mdl '/Step_u'], 'Time', '0.5', 'After', '1', ...
          'SampleTime', 'Ts_task', 'Position', p(30, 40, 30, 30));
add_block('simulink/Sources/Sine Wave', [mdl '/Noise'], 'Amplitude', '0.2', ...
          'Frequency', '2*pi*50', 'SampleTime', 'Ts_task', 'Position', p(30, 90, 30, 30));
add_block('simulink/Math Operations/Sum', [mdl '/Add_noise'], 'Inputs', '++', ...
          'IconShape', 'round', 'Position', p(110, 70, 25, 25));

% Reset: pulse 1 between t = 3.0 s and 3.05 s
add_block('simulink/Sources/Step', [mdl '/Reset_on'],  'Time', '3',    'SampleTime', 'Ts_task', ...
          'Position', p(30, 150, 30, 30));
add_block('simulink/Sources/Step', [mdl '/Reset_off'], 'Time', '3.05', 'SampleTime', 'Ts_task', ...
          'Position', p(30, 200, 30, 30));
add_block('simulink/Math Operations/Sum', [mdl '/Reset_pulse'], 'Inputs', '+-', ...
          'IconShape', 'round', 'Position', p(110, 170, 25, 25));

% Filter time T = 0.1 s
add_block('simulink/Sources/Constant', [mdl '/T_filt'], 'Value', '0.1', ...
          'Position', p(30, 255, 50, 30));

% 1st-order FIR for comparison: y = 0.5*u[k] + 0.5*u[k-1]
add_block('simulink/Discrete/Discrete FIR Filter', [mdl '/FIR_1st_order'], ...
          'Coefficients', '[0.5 0.5]', 'SampleTime', '-1', 'Position', p(330, 260, 90, 40));

add_block('simulink/Signal Routing/Mux', [mdl '/Mux'], 'Inputs', '4', ...
          'Position', p(560, 90, 5, 160));
add_block('simulink/Sinks/Scope', [mdl '/Scope'], 'Position', p(640, 110, 35, 40));
add_block('simulink/Sinks/To Workspace', [mdl '/Log'], 'VariableName', 'pt1_log', ...
          'SaveFormat', 'Structure With Time', 'Position', p(640, 190, 70, 30));

H = @(a, b) add_line(mdl, a, b, 'autorouting', 'on');
H('Step_u/1',      'Add_noise/1');
H('Noise/1',       'Add_noise/2');
H('Reset_on/1',    'Reset_pulse/1');
H('Reset_off/1',   'Reset_pulse/2');
H('Add_noise/1',   'PT1_Filter/1');
H('Reset_pulse/1', 'PT1_Filter/2');
H('T_filt/1',      'PT1_Filter/3');
H('Add_noise/1',   'FIR_1st_order/1');

H('Add_noise/1',     'Mux/1');
H('Reset_pulse/1',   'Mux/2');
H('PT1_Filter/1',    'Mux/3');
H('FIR_1st_order/1', 'Mux/4');
H('Mux/1', 'Scope/1');
H('Mux/1', 'Log/1');

save_system(mdl);
fprintf('Model %s.slx created.\n', mdl);
