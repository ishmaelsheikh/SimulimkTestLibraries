function build_filter_library()
%BUILD_FILTER_LIBRARY  Creates FilterLib.slx in the current folder.
%
%   Blocks (all discrete, task time Ts set in the block mask):
%     PT1_Filter            1st-order low pass        inputs: u, reset, T_filt
%     PT2_Filter            2 x PT1 in series         inputs: u, reset, T_filt
%     HP1_Filter            1st-order high pass       inputs: u, reset, T_filt
%     MovingAverage_Filter  N-sample FIR average      inputs: u, reset
%
%   PT1 law:  y[k] = y[k-1] + K*(u[k] - y[k-1])
%     Method 1  Forward Euler   K = Ts / max(T, Ts)
%     Method 2  Backward Euler  K = Ts / (T + Ts)
%     Method 3  Exact           K = 1 - exp(-Ts / max(T, realmin))
%   T_filt guards: NaN -> 0, negative -> 0. Ts <= 0 is rejected at init.

lib = 'FilterLib';
if bdIsLoaded(lib), close_system(lib, 0); end
if exist([lib '.slx'], 'file'), delete([lib '.slx']); end
new_system(lib, 'Library');

%% PT1_Filter
blk = [lib '/PT1_Filter'];
add_block('built-in/Subsystem', blk, 'Position', [40 40 160 140]);
build_pt1_core(blk);
add_pt_mask(blk, 'PT1', 'PT1 Filter', ...
    'Discrete 1st-order low pass. y = y_prev + K*(u - y_prev). reset ~= 0 sets y = u.', ...
    'Initial output y0');

%% PT2_Filter: two identical PT1 stages in series
blk = [lib '/PT2_Filter'];
add_block('built-in/Subsystem', blk, 'Position', [220 40 340 140]);
add_io(blk, {'u', 'reset', 'T_filt'}, 'y', 520);
add_block('built-in/Subsystem', [blk '/PT1_Stage1'], 'Position', [150 60 250 160]);
build_pt1_core([blk '/PT1_Stage1']);
add_block('built-in/Subsystem', [blk '/PT1_Stage2'], 'Position', [320 60 420 160]);
build_pt1_core([blk '/PT1_Stage2']);
L = @(a, b) add_line(blk, a, b, 'autorouting', 'on');
L('u/1', 'PT1_Stage1/1');          L('reset/1', 'PT1_Stage1/2');  L('T_filt/1', 'PT1_Stage1/3');
L('PT1_Stage1/1', 'PT1_Stage2/1'); L('reset/1', 'PT1_Stage2/2');  L('T_filt/1', 'PT1_Stage2/3');
L('PT1_Stage2/1', 'y/1');
add_pt_mask(blk, 'PT2', 'PT2 Filter', ...
    ['Two identical PT1 stages in series (critically damped 2nd-order low pass), ' ...
     'each with time constant T_filt. reset ~= 0 sets y = u.'], ...
    'Initial output y0 (both stages)');

%% HP1_Filter: y = u - PT1(u)
blk = [lib '/HP1_Filter'];
add_block('built-in/Subsystem', blk, 'Position', [400 40 520 140]);
add_io(blk, {'u', 'reset', 'T_filt'}, 'y', 520);
add_block('built-in/Subsystem', [blk '/PT1_LowPass'], 'Position', [150 60 250 160]);
build_pt1_core([blk '/PT1_LowPass']);
add_block('simulink/Math Operations/Sum', [blk '/HighPass'], 'Inputs', '+-', ...
          'IconShape', 'round', 'Position', [400 25 425 50]);
L = @(a, b) add_line(blk, a, b, 'autorouting', 'on');
L('u/1', 'PT1_LowPass/1'); L('reset/1', 'PT1_LowPass/2'); L('T_filt/1', 'PT1_LowPass/3');
L('u/1', 'HighPass/1');    L('PT1_LowPass/1', 'HighPass/2');
L('HighPass/1', 'y/1');
add_pt_mask(blk, 'HP1', 'HP1 Filter', ...
    ['Discrete 1st-order high pass: y = u - PT1(u). Passes changes, removes the ' ...
     'steady part. reset ~= 0 sets y = 0.'], ...
    'Initial low-pass state y0');

%% MovingAverage_Filter: N-sample FIR (MATLAB Function block)
blk = [lib '/MovingAverage_Filter'];
add_block('built-in/Subsystem', blk, 'Position', [580 40 700 140]);
add_io(blk, {'u', 'reset'}, 'y', 420);
fb = [blk '/MovingAverage'];
add_block('simulink/User-Defined Functions/MATLAB Function', fb, 'Position', [180 30 300 110]);
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', fb);
ch.Script = strjoin({
    'function y = MovingAverage(u, reset, N, y0)'
    '%#codegen'
    '% Average of the last N samples (circular buffer).'
    '% sum(buf) is recomputed every step: no drift from a running sum.'
    'persistent buf k'
    'if isempty(buf)'
    '    buf = y0 * ones(N, 1);'
    '    k = 1;'
    'end'
    'if reset ~= 0'
    '    buf(:) = u;          % reset: fill window with current input -> y = u'
    'else'
    '    buf(k) = u;'
    '    k = k + 1;'
    '    if k > N, k = 1; end'
    'end'
    'y = sum(buf) / N;'
    }, newline);
dN  = ch.find('-isa', 'Stateflow.Data', 'Name', 'N');  dN.Scope  = 'Parameter'; dN.Tunable = false;
dy0 = ch.find('-isa', 'Stateflow.Data', 'Name', 'y0'); dy0.Scope = 'Parameter';
L = @(a, b) add_line(blk, a, b, 'autorouting', 'on');
L('u/1', 'MovingAverage/1'); L('reset/1', 'MovingAverage/2'); L('MovingAverage/1', 'y/1');

m = Simulink.Mask.create(blk);
m.Type = 'Moving Average Filter';
m.Description = ['FIR filter: y = mean of the last N input samples. ' ...
                 'reset ~= 0 fills the window with u (y = u).'];
m.addParameter('Name', 'N',  'Prompt', 'Window length N [samples]', 'Value', '10');
m.addParameter('Name', 'y0', 'Prompt', 'Initial output y0', 'Value', '0');
m.Initialization = ['if ~(isscalar(N) && N >= 1 && N == round(N)), ' ...
                    'error(''Window length N must be an integer >= 1.''); end'];
m.Display = sprintf(['disp(''MovAvg'');\nport_label(''input'',1,''u'');\n' ...
                     'port_label(''input'',2,''reset'');\nport_label(''output'',1,''y'');']);

set_param(lib, 'EnableLBRepository', 'on');   % show in Library Browser (needs slblocks.m)
save_system(lib);
close_system(lib);
fprintf('Library %s.slx created.\n', lib);
end

%% ------------------------------------------------------------------------
function add_io(sys, inNames, outName, xOut)
for i = 1:numel(inNames)
    add_block('simulink/Sources/In1', [sys '/' inNames{i}], 'Port', num2str(i), ...
              'Position', [30 40+70*(i-1) 60 54+70*(i-1)]);
end
add_block('simulink/Sinks/Out1', [sys '/' outName], 'Position', [xOut 30 xOut+30 44]);
end

%% ------------------------------------------------------------------------
function build_pt1_core(sys)
% Fills subsystem SYS with a PT1 filter. Uses Ts, Method, y0 from the
% enclosing mask workspace.
p = @(x, y, w, h) [x y x+w y+h];
A = @(lib, name, pos, varargin) add_block(lib, [sys '/' name], 'Position', pos, varargin{:});

A('simulink/Sources/In1', 'u',      p(30,  40, 30, 14), 'Port', '1');
A('simulink/Sources/In1', 'reset',  p(30, 520, 30, 14), 'Port', '2');
A('simulink/Sources/In1', 'T_filt', p(30, 200, 30, 14), 'Port', '3');
A('simulink/Sinks/Out1',  'y',      p(1060, 115, 30, 14));

% --- T_filt sanitising: NaN -> 0, negative -> 0 ---
A('simulink/Logic and Bit Operations/Relational Operator', 'T_isNaN', p(110, 250, 40, 30), ...
  'Operator', 'isNaN');
A('simulink/Sources/Constant', 'Zero', p(110, 300, 30, 26), 'Value', '0');
A('simulink/Signal Routing/Switch', 'T_NaN_to_0', p(190, 190, 40, 70), 'Criteria', 'u2 ~= 0');
A('simulink/Math Operations/MinMax', 'T_safe', p(270, 200, 35, 50), 'Function', 'max', 'Inputs', '2');
A('simulink/Sources/Constant', 'Ts', p(270, 330, 40, 26), 'Value', 'Ts');

% --- Method 1: Forward Euler  K = Ts / max(T, Ts) ---
A('simulink/Math Operations/MinMax', 'T_max_Ts', p(370, 150, 35, 40), 'Function', 'max', 'Inputs', '2');
A('simulink/Math Operations/Divide', 'K_forward', p(450, 150, 35, 40), 'Inputs', '*/');
% --- Method 2: Backward Euler K = Ts / (T + Ts) ---
A('simulink/Math Operations/Sum', 'T_plus_Ts', p(370, 230, 25, 25), 'Inputs', '++', 'IconShape', 'round');
A('simulink/Math Operations/Divide', 'K_backward', p(450, 225, 35, 40), 'Inputs', '*/');
% --- Method 3: Exact          K = 1 - exp(-Ts / max(T, realmin)) ---
A('simulink/Sources/Constant', 'Realmin', p(270, 400, 50, 26), 'Value', 'realmin');
A('simulink/Math Operations/MinMax', 'T_max_min', p(370, 300, 35, 40), 'Function', 'max', 'Inputs', '2');
A('simulink/Math Operations/Divide', 'Ts_div_T', p(450, 300, 35, 40), 'Inputs', '*/');
A('simulink/Math Operations/Unary Minus', 'Neg', p(510, 305, 30, 30));
A('simulink/Math Operations/Math Function', 'Exp', p(565, 305, 40, 30), 'Operator', 'exp');
A('simulink/Sources/Constant', 'One', p(565, 360, 30, 26), 'Value', '1');
A('simulink/Math Operations/Sum', 'K_exact', p(640, 310, 25, 25), 'Inputs', '+-', 'IconShape', 'round');

% --- method selection (only the selected branch executes) ---
A('simulink/Sources/Constant', 'Method', p(640, 130, 50, 26), 'Value', 'Method');
A('simulink/Signal Routing/Multiport Switch', 'K_select', p(720, 130, 40, 200), ...
  'Inputs', '3', 'DataPortOrder', 'One-based contiguous');

% --- filter core ---
A('simulink/Math Operations/Sum', 'Err', p(250, 40, 25, 25), 'Inputs', '+-', 'IconShape', 'round');
A('simulink/Math Operations/Product', 'K_x_Err', p(800, 45, 35, 50));
A('simulink/Math Operations/Sum', 'Integrate', p(870, 57, 25, 25), 'Inputs', '++', 'IconShape', 'round');
A('simulink/Signal Routing/Switch', 'Reset_Switch', p(960, 100, 40, 60), 'Criteria', 'u2 ~= 0');
A('simulink/Discrete/Unit Delay', 'y_prev', p(900, 440, 35, 35), ...
  'InitialCondition', 'y0', 'SampleTime', '-1', 'Orientation', 'left');

L = @(a, b) add_line(sys, a, b, 'autorouting', 'on');
L('T_filt/1', 'T_isNaN/1');   L('Zero/1', 'T_NaN_to_0/1');  L('T_isNaN/1', 'T_NaN_to_0/2');
L('T_filt/1', 'T_NaN_to_0/3');
L('T_NaN_to_0/1', 'T_safe/1'); L('Zero/1', 'T_safe/2');

L('T_safe/1', 'T_max_Ts/1');  L('Ts/1', 'T_max_Ts/2');
L('Ts/1', 'K_forward/1');     L('T_max_Ts/1', 'K_forward/2');

L('T_safe/1', 'T_plus_Ts/1'); L('Ts/1', 'T_plus_Ts/2');
L('Ts/1', 'K_backward/1');    L('T_plus_Ts/1', 'K_backward/2');

L('T_safe/1', 'T_max_min/1'); L('Realmin/1', 'T_max_min/2');
L('Ts/1', 'Ts_div_T/1');      L('T_max_min/1', 'Ts_div_T/2');
L('Ts_div_T/1', 'Neg/1');     L('Neg/1', 'Exp/1');
L('One/1', 'K_exact/1');      L('Exp/1', 'K_exact/2');

L('Method/1', 'K_select/1');
L('K_forward/1', 'K_select/2'); L('K_backward/1', 'K_select/3'); L('K_exact/1', 'K_select/4');

L('u/1', 'Err/1');            L('y_prev/1', 'Err/2');
L('Err/1', 'K_x_Err/1');      L('K_select/1', 'K_x_Err/2');
L('K_x_Err/1', 'Integrate/1'); L('y_prev/1', 'Integrate/2');
L('u/1', 'Reset_Switch/1');   L('reset/1', 'Reset_Switch/2');  L('Integrate/1', 'Reset_Switch/3');
L('Reset_Switch/1', 'y/1');   L('Reset_Switch/1', 'y_prev/1');
end

%% ------------------------------------------------------------------------
function add_pt_mask(blk, label, typeName, desc, y0Prompt)
m = Simulink.Mask.create(blk);
m.Type = typeName;
m.Description = desc;
m.addParameter('Name', 'Ts', 'Prompt', 'Task time Ts [s]', 'Value', '0.01');
m.addParameter('Type', 'popup', 'Name', 'Method', 'Prompt', 'Discretisation method', ...
    'TypeOptions', {'Forward Euler: K = Ts/T', 'Backward Euler: K = Ts/(T+Ts)', ...
                    'Exact: K = 1-exp(-Ts/T)'}, ...
    'Value', 'Forward Euler: K = Ts/T');
m.addParameter('Name', 'y0', 'Prompt', y0Prompt, 'Value', '0');
m.Initialization = ['if ~(isscalar(Ts) && isfinite(Ts) && Ts > 0), ' ...
                    'error(''Task time Ts must be a positive, finite scalar.''); end'];
m.Display = sprintf(['disp(''%s'');\nport_label(''input'',1,''u'');\n' ...
                     'port_label(''input'',2,''reset'');\nport_label(''input'',3,''T_filt'');\n' ...
                     'port_label(''output'',1,''y'');'], label);
end
