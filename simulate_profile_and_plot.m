function out = simulate_profile_and_plot(modelName, t_seconds, load_kW, varargin)
% SIMULATE_PROFILE_AND_PLOT – Jahr-geeignet (15-min), mit Datetime-Achse, Zoom & Decimation
% Plots:
%  1) Last & Unserved
%  2) Netzleistung (separat)
%  3) Batterieenergie / SOC
%  4) Serve-Ratio (mit Schwelle) + Cover-Ratio
%  (+) eigene Figur: Heatmap der täglichen Cover-Ratio
%
% Name-Value-Params:
%   'E_kWh'         (double)  installierte Batteriegröße [kWh], default 2000
%   'P_grid_kW'     (double)  max. Netzanschluss [kW],         default 1000
%   'E0_kWh'        (double)  Startenergie [kWh],               default min(120,E_kWh)
%   'dt'            (double)  fixer Sim-Schritt [s],            default 60
%   'minServeRatio' (double)  Schwelle Serve-Ratio,             default 0.90
%   'solver'        (char)    'ode3' | 'discrete',              default 'ode3'
%   't0'            (datetime)Startzeit (für Achse),            default datetime(2025,1,1)
%   'xrange'        (1x2 datetime) sichtbarer Plotbereich       default [] (ganzer Bereich)
%   'maxPlotPts'    (double)  max. Punkte pro Kurve (Decimation) default 60000
%
% Erwartete To-Workspace Signale (Base-WS):
%   Pflicht:  Unserved_ws
%   Optional: E_kWh_ws, Grid_ws (dein Name) oder weitere Alternativen

% ---- Defaults / Inputs ----
p = inputParser;
addParameter(p,'E_kWh',        2000);
addParameter(p,'P_grid_kW',    1000);
addParameter(p,'E0_kWh',       []);
addParameter(p,'dt',           60);
addParameter(p,'minServeRatio',0.90);
addParameter(p,'solver','ode3');
addParameter(p,'t0', datetime(2025,1,1));
addParameter(p,'xrange', []);
addParameter(p,'maxPlotPts', 60000);
parse(p,varargin{:});
cfg = p.Results;
if isempty(cfg.E0_kWh), cfg.E0_kWh = min(120, cfg.E_kWh); end

% ---- Datetime-Achse aus Sekunden bauen ----
t0s = t_seconds(1);
t_dt = cfg.t0 + seconds(t_seconds - t0s);

% ---- Solver fixieren ----
if ~bdIsLoaded(modelName), open_system(modelName); end
set_param(modelName, ...
    'SolverType','Fixed-step', ...
    'Solver',cfg.solver, ...
    'FixedStep', num2str(cfg.dt), ...
    'MaxConsecutiveMinStep','1000');

% ---- Lastprofil ins Base-WS ----
Load_ts = timeseries(load_kW(:), t_seconds(:));
assignin('base','Load_ts',Load_ts);
try, set_param(modelName,'StopTime',num2str(t_seconds(end))); end

% ---- Parameter in ModelWorkspace ----
mdlW = get_param(modelName,'ModelWorkspace');
assignin(mdlW,'E_nom',      max(cfg.E_kWh,0));
assignin(mdlW,'P_grid_max', max(cfg.P_grid_kW,0));

% Startenergie setzen (falls Block vorhanden)
try
    IC = min(max(cfg.E0_kWh,0), cfg.E_kWh);
    set_param([modelName '/Int_Energy'],'InitialCondition', num2str(IC));
catch
    % still
end

% ---- Simulieren ----
try, save_system(modelName, [], 'OverwriteIfChangedOnDisk', true); end
set_param(modelName,'SimulationCommand','update');
evalin('base', sprintf("sim('%s');", modelName));

% ---- Signale holen ----
XY_unserved = grab_ws_signal('Unserved_ws');                            % Pflicht
XY_E        = grab_ws_signal('E_kWh_ws');                               % optional
XY_grid     = first_exist({'Grid_ws','P_grid_ws','GridPower_ws', ...    % bevorzugt: Grid_ws
                           'Pgrid_ws','Grid_kw_ws','P_net_ws','P_from_grid_ws'});

% Auf Zeitachse legen (previous-step Interp)
u        = interp_prev(XY_unserved, t_seconds);
grid_kW  = interp_prev(XY_grid,     t_seconds);
E        = interp_prev(XY_E,        t_seconds);

% Serve-/Cover
load_vec   = load_kW(:);
den        = max(load_vec, 1e-6);
serveRatio = (load_vec - u) ./ den;
serveRatio(load_vec < 1e-6) = 1;
coverRatio = mean(serveRatio >= cfg.minServeRatio);

% SOC
SOC = [];
if ~isempty(E), SOC = E / max(cfg.E_kWh,1e-9); end

% ---- Sichtfenster / Decimation NUR für Plot ----
[tP, loadP] = decimate_for_plot(t_dt, load_vec,   cfg.maxPlotPts, cfg.xrange);
[~,   uP  ] = decimate_for_plot(t_dt, u,          cfg.maxPlotPts, cfg.xrange);
[~,   gridP] = decimate_for_plot(t_dt, grid_kW,   cfg.maxPlotPts, cfg.xrange);
[~,   EP  ] = decimate_for_plot(t_dt, E,          cfg.maxPlotPts, cfg.xrange);
[~,   srP ] = decimate_for_plot(t_dt, serveRatio, cfg.maxPlotPts, cfg.xrange);

% ---- Plots ----
figure('Name','Ladepark – Jahresprofil (15 min)','Color','w');

hasGrid = ~isempty(gridP);
if hasGrid
    tiledlayout(4,1,'Padding','compact','TileSpacing','compact');
else
    tiledlayout(3,1,'Padding','compact','TileSpacing','compact');
end

% 1) Last & Unserved
nexttile;
plot(tP, loadP,'LineWidth',1.2); hold on; grid on;
plot(tP, uP,   'LineWidth',1.2, 'LineStyle','--');
ylabel('Leistung [kW]');
title('Last & Unserved');
legend({'Last','Unserved'},'Location','best');
xfmt();

% 2) Netzleistung separat
if hasGrid
    nexttile;
    plot(tP, gridP,'LineWidth',1.8); grid on;
    yline(cfg.P_grid_kW,':','P_{grid,max}','LabelHorizontalAlignment','left');
    ylabel('Leistung [kW]');
    title('Netzleistung (separat)');
    xfmt();
end

% 3) Batterieenergie / SOC
nexttile;
if ~isempty(EP)
    yyaxis left;  plot(tP, EP,'LineWidth',1.2); ylabel('E [kWh]');
    yyaxis right; if ~isempty(SOC)
        [tPS, SOCP] = decimate_for_plot(t_dt, SOC, cfg.maxPlotPts, cfg.xrange);
        plot(tPS, SOCP,'LineWidth',1.2, 'LineStyle',':'); ylabel('SOC [-]');
    end
    grid on; title('Batterie – Energie / SOC'); xfmt();
else
    text(0.5,0.5,'Kein E\_kWh\_ws gefunden','HorizontalAlignment','center'); axis off;
end

% 4) Serve-Ratio + Schwelle
nexttile;
plot(tP, srP,'LineWidth',1.2); hold on; grid on;
yline(cfg.minServeRatio,'--','Min Serve Ratio','LabelHorizontalAlignment','left');
ylim([0 1.05]); ylabel('Serve-Ratio');
title(sprintf('Serve-Ratio | Cover-Ratio = %.3f', coverRatio));
xfmt();

% 5) Heatmap: tägliche Cover-Ratio (eigene Figur)
try
    [cov_by_day, days] = cover_by_day(t_dt, serveRatio, cfg.minServeRatio);
    figure('Name','Cover-Ratio pro Tag','Color','w');
    imagesc(days, 1, cov_by_day'); colormap(parula); colorbar;
    set(gca,'YTick',[]); ylim([0.5 1.5]);
    title('Cover-Ratio pro Tag');
    xticks(dateshift(days(1),'start','month'):calmonths(1):dateshift(days(end),'start','month')+calmonths(1));
    xtickformat('MMM');
    xlabel('Zeit');
catch
    % still
end

% ---- Rückgabe ----
out = struct('coverRatio',coverRatio, 'serveRatio',serveRatio, ...
             't',t_dt, 'load',load_vec, 'unserved',u, 'grid',grid_kW, ...
             'E_kWh',E, 'SOC',SOC, 'params',cfg);

% ======= lokale Helfer =======
    function XY = grab_ws_signal(varname)
        XY = struct('t',[],'y',[]);
        if evalin('base', sprintf('exist(''%s'',''var'')', varname)) == 1
            S  = evalin('base', varname);
            XY = swt2xy_local(S);
        end
    end

    function XY = first_exist(candidates)
        XY = struct('t',[],'y',[]);
        for ii=1:numel(candidates)
            if evalin('base', sprintf('exist(''%s'',''var'')', candidates{ii})) == 1
                XY = swt2xy_local(evalin('base',candidates{ii}));
                if ~isempty(XY.t), return; end
            end
        end
    end

    function y = interp_prev(XY, tsec)
        if isempty(XY) || ~isfield(XY,'t') || isempty(XY.t)
            y = zeros(size(tsec));
            return;
        end
        y = interp1(XY.t(:), XY.y(:), tsec(:), 'previous', 'extrap');
    end

    function [tOut, yOut] = decimate_for_plot(tAll, yAll, maxN, xr)
        mask = true(size(tAll));
        if ~isempty(xr), mask = (tAll>=xr(1) & tAll<=xr(2)); end
        tSel = tAll(mask); ySel = yAll(mask);
        n = numel(tSel);
        if n>maxN && maxN>0
            idx = unique(round(linspace(1,n,maxN)));
            tOut = tSel(idx); yOut = ySel(idx);
        else
            tOut = tSel; yOut = ySel;
        end
    end

    function xfmt()
        % Monats-Ticks über den sichtbaren Bereich (oder xrange)
        ax = gca;
        if ~isempty(cfg.xrange)
            tmin = cfg.xrange(1); tmax = cfg.xrange(2);
        else
            if isa(ax.XLim,'datetime')
                tmin = ax.XLim(1); tmax = ax.XLim(2);
            else
                lim  = ax.XLim;
                tmin = datetime(lim(1),'ConvertFrom','datenum');
                tmax = datetime(lim(2),'ConvertFrom','datenum');
            end
        end
        tmin  = dateshift(tmin,'start','month');
        tmax2 = dateshift(tmax,'start','month') + calmonths(1);
        xticks(tmin:calmonths(1):tmax2);
        xtickformat('MMM'); % Jan, Feb, ...
        xlabel('Zeit');
    end

    function [covDay, days] = cover_by_day(tDT, sr, thr)
        TT = timetable(tDT(:), sr(:), 'VariableNames', {'sr'});
        TT.serve_hit = TT.sr >= thr;
        G = retime(TT,'daily','mean');       % Mittelwert pro Tag
        covDay = G.serve_hit;
        days   = G.Time;
    end

    function XY = swt2xy_local(S)
        if isstruct(S) && isfield(S,'time') && isfield(S,'signals')
            t0 = S.time(:); v = S.signals.values;
        elseif isstruct(S) && isfield(S,'signals') && isfield(S.signals,'values')
            t0 = evalin('base','tout(:)'); v = S.signals.values;
        elseif isa(S,'timeseries')
            t0 = S.Time(:); v = S.Data;
        elseif isa(S,'Simulink.SimulationData.Dataset')
            assert(S.numElements>0,'Dataset ist leer.');
            V = S.get(1).Values; t0 = V.Time(:); v = V.Data(:);
        elseif isnumeric(S) && ~isempty(S)
            t0 = evalin('base','tout(:)'); v = S(:);
        elseif isa(S,'timetable')
            t0 = S.Time(:); vars = setdiff(S.Properties.VariableNames, {'Time'}); v = S.(vars{1})(:);
        elseif istable(S)
            t0 = evalin('base','tout(:)'); v = S{:,1};
        else
            t0 = []; v = [];
        end
        if ismatrix(v) && size(v,2) > 1, v = v(:,1); end
        XY.t = t0(:); XY.y = v(:);
    end
end
