function run_battery_sim_and_plot_jahr(modelName, t_in, load_kW, minServeRatio, E0_kWh)
% wie gehabt ...

if nargin < 4 || isempty(minServeRatio), minServeRatio = 0.90; end
if nargin < 5, E0_kWh = []; end
assert(~isempty(modelName),'Bitte modelName angeben.');

% --- (A) Zeitachse robust normalisieren (-> Sekunden ab 0) & Plot-Konverter
[t_sec, xfun, xlab] = normalize_time_axis_for_sim_and_plot(t_in);

% Doppelte Zeitstempel vermeiden (Simulink mag das nicht)
[t_sec_u, uniq_idx] = unique(t_sec,'stable');
load_kW_u = load_kW(:);
if numel(load_kW_u) ~= numel(t_sec)
    error('Längen passen nicht: t_in (%d) vs. load_kW (%d).', numel(t_sec), numel(load_kW));
end
load_kW_u = load_kW_u(uniq_idx);

% --- (B) Modell laden & Settings
if ~bdIsLoaded(modelName), open_system(modelName); end
set_param(modelName,'FastRestart','off');

% Last ins Base (Timeseries in Sekunden)
Load_ts = timeseries(load_kW_u(:), t_sec_u(:));
assignin('base','Load_ts',Load_ts);

% StopTime passend in Sekunden
try, set_param(modelName,'StopTime',num2str(t_sec_u(end))); end

% --- (C) Optionale absolute Startenergie setzen
if ~isempty(E0_kWh)
    IC = E0_kWh;
    try
        mdlW  = get_param(modelName,'ModelWorkspace');
        E_nom = evalin(mdlW,'E_nom');
        if isfinite(E_nom), IC = min(max(E0_kWh,0), E_nom); end
    catch, end
    try
        set_param([modelName '/Int_Energy'],'InitialCondition', num2str(IC));
    catch
        warning('Konnte InitialCondition nicht setzen (Blockpfad prüfen).');
    end
    set_param(modelName,'SimulationCommand','update');
end

% --- (D) Simulation
evalin('base', sprintf("sim('%s');", modelName));

% --- (E) Outputs laden
E_raw  = evalin('base','E_kWh_ws');
S_raw  = evalin('base','SOC_ws');
Pi_raw = evalin('base','P_int_ws');
Pl_raw = evalin('base','P_lim_ws');
G_raw  = evalin('base','Grid_ws');
U_raw  = evalin('base','Unserved_ws');

E  = swt2xy(E_raw);   S  = swt2xy(S_raw);
Pi = swt2xy(Pi_raw);  Pl = swt2xy(Pl_raw);
G  = swt2xy(G_raw);   U  = swt2xy(U_raw);

% Cover/Served-Ratio auf deinem Profilraster
[coverFrac, sr_eval] = cover_on_profile(t_sec_u(:), load_kW_u(:), U_raw, minServeRatio);

% SOC-abhängige Laderate
Cc_t = [];
try
    mdlW   = get_param(modelName,'ModelWorkspace');
    soc_bp = evalin(mdlW,'soc_bp');
    Cc_tab = evalin(mdlW,'Cc_tab');
    Cc_t   = interp1(soc_bp(:), Cc_tab(:), S.y, 'pchip','extrap');
catch, end

% --- (F) Plots mit korrekter X-Achse
figure('Name','Battery + Grid – Outputs (inkl. Last, Cc(SOC), Served-Ratio)','Color','w');
tiledlayout(3,3,'Padding','compact','TileSpacing','compact');

% Hilfsfunktion für X: Sekunden -> richtige Achse
xE  = xfun(E.t);  xS  = xfun(S.t);  xPi = xfun(Pi.t);
xPl = xfun(Pl.t); xG  = xfun(G.t);  xU  = xfun(U.t);
xLd = xfun(t_sec_u);

nexttile; plot(xE,  E.y);  grid on; xlabel(xlab); ylabel('E [kWh]');      title('E\_kWh');
nexttile; plot(xS,  S.y);  grid on; xlabel(xlab); ylabel('SOC [-]');      title('SOC');
nexttile; plot(xG,  G.y);  grid on; xlabel(xlab); ylabel('P_{grid} [kW]');title('Grid\_power\_kW');
nexttile; plot(xU,  U.y);  grid on; xlabel(xlab); ylabel('Unserved [kW]');title('Unserved\_load\_kW');
nexttile; plot(xPi, Pi.y); grid on; xlabel(xlab); ylabel('P_{int} [kW]'); title('P\_int\_kW');
nexttile; plot(xPl, Pl.y); grid on; xlabel(xlab); ylabel('P_{lim} [kW]'); title('P\_{lim}\_kW');
nexttile; plot(xLd, load_kW_u,'LineWidth',1.2); grid on; xlabel(xlab); ylabel('Load [kW]'); title('Load\_kW (Input)');

nexttile;
if ~isempty(Cc_t)
    plot(xS, Cc_t,'LineWidth',1.0); grid on;
    xlabel(xlab); ylabel('C_c [1/h]'); title('SOC-abh. Laderate C_c(SOC(t))');
else
    text(0.1,0.5,'Cc\_tab nicht gefunden','FontSize',10); axis off
end

nexttile;
plot(xLd, sr_eval, 'LineWidth',1.0); hold on;
yline(minServeRatio,'--'); grid on; ylim([0 1.05]);
xlabel(xlab); ylabel('Served-Ratio [-]');
title(sprintf('Served-Ratio (Cover=%.3f, Schwelle=%.2f)', coverFrac, minServeRatio));

disp('Fertig: Simulation + Plots (mit robuster Zeitachse).');
end

% ===== Helper: Zeit normalisieren & Plot-Achse definieren =====
function [t_sec, xfun, xlab] = normalize_time_axis_for_sim_and_plot(t_in)
    % Liefert Sekunden ab 0 (t_sec) für Simulink
    % und eine xfun(seconds)->PlotX sowie xlab.
    if isdatetime(t_in)
        t0   = t_in(1);
        t_sec = seconds(t_in - t0);
        xfun  = @(ts) t0 + seconds(ts);
        xlab  = 'Zeit';
        return
    elseif isduration(t_in)
        t0   = t_in(1);
        t_sec = seconds(t_in - t0);
        xfun  = @(ts) t0 + seconds(ts);
        xlab  = 'Zeit';
        return
    end

    % numerisch: Stunden/Tage/ Sekunden erkennen
    t = t_in(:);
    t = t - t(1);
    dt = median(diff(t(~isnan(t))));
    T  = t(end);

    % Heuristiken
    if T <= 10 && abs(dt - 0.0104167) < 5e-4      % ≈ 15 min in Tagen
        t_sec = t * 86400;                         % Tage -> s
    elseif T <= 72 && dt >= 0.1 && dt <= 2         % Stundenraster (z.B. 0.25 h)
        t_sec = t * 3600;                          % h -> s
    else
        t_sec = t;                                 % bereits Sekunden (oder Indizes)
    end

    % Plot standardmäßig in Stunden
    xfun = @(ts) ts/3600;
    xlab = 'Zeit [h]';
end

% ===== Deine bestehenden Helper (unverändert) =====
% -> swt2xy(...)
% -> cover_on_profile(...)
