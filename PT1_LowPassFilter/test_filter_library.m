%% test_filter_library.m
% Builds FilterLib.slx and a harness FilterLib_Test.slx (library links),
% checks every block against a MATLAB reference, then plots the results.
build_filter_library;
load_system('FilterLib');

h = 'FilterLib_Test';
if bdIsLoaded(h), close_system(h, 0); end
if exist([h '.slx'], 'file'), delete([h '.slx']); end
new_system(h);
Ts_task = 0.001;
set_param(h, 'PreLoadFcn', 'Ts_task = 0.001;', 'InitFcn', 'if ~exist(''Ts_task'',''var''), Ts_task = 0.001; end', ...
          'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', 'FixedStep', 'Ts_task', 'StopTime', '5');

p = @(x, y, w, h_) [x y x+w y+h_];
add_block('simulink/Sources/Step', [h '/Step_u'], 'Time', '0.5', 'SampleTime', 'Ts_task', 'Position', p(30, 40, 30, 30));
add_block('simulink/Sources/Sine Wave', [h '/Noise'], 'Amplitude', '0.2', 'Frequency', '2*pi*50', ...
          'SampleTime', 'Ts_task', 'Position', p(30, 90, 30, 30));
add_block('simulink/Math Operations/Sum', [h '/u'], 'Inputs', '++', 'IconShape', 'round', 'Position', p(100, 70, 25, 25));
add_block('simulink/Sources/Step', [h '/Reset_on'],  'Time', '3',    'SampleTime', 'Ts_task', 'Position', p(30, 160, 30, 30));
add_block('simulink/Sources/Step', [h '/Reset_off'], 'Time', '3.05', 'SampleTime', 'Ts_task', 'Position', p(30, 210, 30, 30));
add_block('simulink/Math Operations/Sum', [h '/reset'], 'Inputs', '+-', 'IconShape', 'round', 'Position', p(100, 185, 25, 25));
add_block('simulink/Sources/Constant', [h '/T_filt'], 'Value', '0.1', 'Position', p(30, 270, 50, 30));

blocks = {'PT1_Filter', 'PT2_Filter', 'HP1_Filter', 'MovingAverage_Filter'};
for i = 1:numel(blocks)
    add_block(['FilterLib/' blocks{i}], [h '/' blocks{i}], 'Position', p(250, 30+110*(i-1), 110, 80));
end
for i = 1:3, set_param([h '/' blocks{i}], 'Ts', 'Ts_task'); end
set_param([h '/MovingAverage_Filter'], 'N', '20');

add_block('simulink/Signal Routing/Mux', [h '/Mux'], 'Inputs', '6', 'Position', p(480, 30, 5, 400));
add_block('simulink/Sinks/Scope', [h '/Scope'], 'Position', p(560, 200, 35, 40));
add_block('simulink/Sinks/To Workspace', [h '/Log'], 'VariableName', 'flog', ...
          'SaveFormat', 'Structure With Time', 'Position', p(560, 300, 70, 30));
H = @(a, b) add_line(h, a, b, 'autorouting', 'on');
H('Step_u/1', 'u/1'); H('Noise/1', 'u/2'); H('Reset_on/1', 'reset/1'); H('Reset_off/1', 'reset/2');
for i = 1:numel(blocks)
    H('u/1', [blocks{i} '/1']); H('reset/1', [blocks{i} '/2']);
    if i <= 3, H('T_filt/1', [blocks{i} '/3']); end
    H([blocks{i} '/1'], sprintf('Mux/%d', i+2));
end
H('u/1', 'Mux/1'); H('reset/1', 'Mux/2'); H('Mux/1', 'Scope/1'); H('Mux/1', 'Log/1');
save_system(h);

%% 1) Every method x every filter time vs. MATLAB reference
methods = {'Forward Euler: K = Ts/T', 'Backward Euler: K = Ts/(T+Ts)', 'Exact: K = 1-exp(-Ts/T)'};
Tcases  = {'0.1', '0.0005', '0', '-1', 'NaN'};
Ts = Ts_task;  worst = 0;  nonfinite = false;
fprintf('\n%-32s %-8s %-11s %-11s %-11s\n', 'Method', 'T_filt', 'PT1 err', 'PT2 err', 'HP1 err');
for mi = 1:3
    for i = 1:3, set_param([h '/' blocks{i}], 'Method', methods{mi}); end
    for ti = 1:numel(Tcases)
        set_param([h '/T_filt'], 'Value', Tcases{ti});
        o = sim(h, 'ReturnWorkspaceOutputs', 'on');
        v = o.get('flog').signals.values;  u = v(:,1);  r = v(:,2);  T = str2double(Tcases{ti});
        lp  = ref_pt1(u,  r, T, Ts, mi, 0);
        e1 = max(abs(v(:,3) - lp));
        e2 = max(abs(v(:,4) - ref_pt1(lp, r, T, Ts, mi, 0)));
        e3 = max(abs(v(:,5) - (u - lp)));
        worst = max([worst e1 e2 e3]);
        nonfinite = nonfinite || any(~isfinite(v(:)));
        fprintf('%-32s %-8s %-11.2e %-11.2e %-11.2e\n', methods{mi}, Tcases{ti}, e1, e2, e3);
    end
end
fprintf('Worst error vs reference: %.2e   Any NaN/Inf output: %d\n', worst, nonfinite);
set_param([h '/T_filt'], 'Value', '0.1');

%% 2) Moving average vs reference
o = sim(h, 'ReturnWorkspaceOutputs', 'on');  v = o.get('flog').signals.values;
fprintf('MovingAverage (N=20) max error vs reference: %.2e\n', max(abs(v(:,6) - ref_ma(v(:,1), v(:,2), 20, 0))));

%% 3) Invalid mask parameters must be rejected
bad = {'PT1_Filter', 'Ts', '0', 'Ts_task'; 'PT2_Filter', 'Ts', '-0.001', 'Ts_task'; ...
       'HP1_Filter', 'Ts', 'NaN', 'Ts_task'; 'MovingAverage_Filter', 'N', '2.5', '20'};
for i = 1:size(bad, 1)
    try
        set_param([h '/' bad{i,1}], bad{i,2}, bad{i,3});  sim(h);
        fprintf('%-21s %s = %-6s -> NOT rejected (FAIL)\n', bad{i,1}, bad{i,2}, bad{i,3});
    catch e
        c = e;  while ~isempty(c.cause), c = c.cause{1}; end   % innermost message
        fprintf('%-21s %s = %-6s -> rejected: %s\n', bad{i,1}, bad{i,2}, bad{i,3}, c.message);
    end
    set_param([h '/' bad{i,1}], bad{i,2}, bad{i,4});
end

%% 4) Plot (Exact method, T = 0.1 s)
for i = 1:3, set_param([h '/' blocks{i}], 'Method', methods{3}); end
save_system(h);
o = sim(h, 'ReturnWorkspaceOutputs', 'on');  d = o.get('flog');  t = d.time;  v = d.signals.values;
f = figure('Visible', 'off', 'Position', [100 100 1100 650]);
subplot(3,1,[1 2]);
plot(t, v(:,1), 'Color', [0.8 0.8 0.8]); hold on;
plot(t, v(:,6), 'Color', [0 0.6 0], 'LineWidth', 1);
plot(t, v(:,3), 'b', 'LineWidth', 1.5);
plot(t, v(:,4), 'm', 'LineWidth', 1.5);
plot(t, v(:,5), 'Color', [0.9 0.5 0], 'LineWidth', 1);
grid on; ylabel('value'); title('FilterLib blocks, T\_filt = 0.1 s, Exact method, Ts = 1 ms');
legend('input u', 'MovingAverage N=20', 'PT1', 'PT2', 'HP1', 'Location', 'east');
subplot(3,1,3); plot(t, v(:,2), 'r', 'LineWidth', 1.5); grid on; ylim([-0.2 1.2]);
xlabel('time [s]'); ylabel('reset');
print(f, 'filterlib_result.png', '-dpng', '-r110');
close_system(h); close_system('FilterLib');
fprintf('Plot saved to filterlib_result.png\n');

%% ------------------------------------------------------------------------
function y = ref_pt1(u, r, T, Ts, method, y0)
if isnan(T), T = 0; end
T = max(T, 0);
switch method
    case 1, K = Ts / max(T, Ts);
    case 2, K = Ts / (T + Ts);
    case 3, K = 1 - exp(-Ts / max(T, realmin));
end
y = zeros(size(u));  yp = y0;
for k = 1:numel(u)
    if r(k) ~= 0, y(k) = u(k); else, y(k) = (u(k) - yp) * K + yp; end
    yp = y(k);
end
end

function y = ref_ma(u, r, N, y0)
buf = y0 * ones(N, 1);  j = 1;  y = zeros(size(u));
for k = 1:numel(u)
    if r(k) ~= 0, buf(:) = u(k); else, buf(j) = u(k); j = mod(j, N) + 1; end
    y(k) = sum(buf) / N;
end
end
