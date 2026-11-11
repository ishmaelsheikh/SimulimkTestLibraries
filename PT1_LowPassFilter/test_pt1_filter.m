%% test_pt1_filter.m  - builds the model, verifies it, plots results
build_pt1_filter;
mdl = 'PT1_Filter_Demo';
T = 0.1;

% 1) Noise-free run: compare with analytic step response 1 - exp(-t/T)
set_param([mdl '/Noise'], 'Amplitude', '0');
out = sim(mdl, 'ReturnWorkspaceOutputs', 'on');
d = out.get('pt1_log');  t = d.time;  v = d.signals.values;
y = v(:,3);  rst = v(:,2);
idx = t >= 0.5 & t < 3;
y_ref = 1 - exp(-(t(idx) - 0.5) / T);
fprintf('Max |PT1 - analytic| before reset: %.4f\n', max(abs(y(idx) - y_ref)));
fprintf('y at t = 0.5+T (expect ~0.632):    %.4f\n', interp1(t, y, 0.6));
fprintf('During reset, max |y - u|:         %.2e\n', max(abs(y(rst ~= 0) - v(rst ~= 0, 1))));

% Reference: user's formula evaluated sample by sample in MATLAB
Ts = 0.001;  u = v(:,1);  yr = zeros(size(u));  yp = 0;
for k = 1:numel(u)
    if rst(k) ~= 0, yr(k) = u(k);
    else,           yr(k) = (u(k) - yp) * (Ts / max(T, Ts)) + yp;
    end
    yp = yr(k);
end
fprintf('Max |model - formula| (whole run):  %.2e\n', max(abs(y - yr)));

% Guard check: T_filt = 0 must give pass-through, not Inf/NaN
set_param([mdl '/T_filt'], 'Value', '0');
out0 = sim(mdl, 'ReturnWorkspaceOutputs', 'on');  v0 = out0.get('pt1_log').signals.values;
fprintf('T_filt = 0 -> max |y - u|:          %.2e\n', max(abs(v0(:,3) - v0(:,1))));
set_param([mdl '/T_filt'], 'Value', '0.1');

% 2) Noisy run for the plot
set_param([mdl '/Noise'], 'Amplitude', '0.2');
save_system(mdl);
out = sim(mdl, 'ReturnWorkspaceOutputs', 'on');
d = out.get('pt1_log');  t = d.time;  v = d.signals.values;

f = figure('Visible', 'off', 'Position', [100 100 1000 550]);
subplot(2,1,1);
plot(t, v(:,1), 'Color', [0.75 0.75 0.75]); hold on;
plot(t, v(:,4), 'g', 'LineWidth', 1);
plot(t, v(:,3), 'b', 'LineWidth', 1.5);
grid on; legend('input u (step + 50 Hz noise)', '1st-order FIR [0.5 0.5]', 'PT1, K = Ts/T, T = 0.1 s', 'Location', 'southeast');
title('PT1 vs 1st-order FIR'); ylabel('value');
subplot(2,1,2);
plot(t, v(:,2), 'r', 'LineWidth', 1.5); grid on; ylim([-0.2 1.2]);
xlabel('time [s]'); ylabel('reset');
print(f, 'pt1_result.png', '-dpng', '-r110');
fprintf('Plot saved to pt1_result.png\n');
