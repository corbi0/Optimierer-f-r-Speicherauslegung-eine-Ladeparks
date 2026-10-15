function [time_day, P_load, E_total, E_target_reached] = Lastprofil_LKW_Ladestation_2(dt, Bedarfenergie, Anschlusspunkte, LKW_Batt_Leistung, Anzahl_Peaks_Tag, peak_hour)
% Sinusförmiges Tagesprofil mit N
% Peaks, jeweils 2h flachem Plateau bei P_max
%
% Inputs:
%   dt                - Zeitschritt [s]
%   Bedarfenergie     - Tagesenergie [kWh]
%   Anschlusspunkte   - Anzahl Ladepunkte
%   LKW_Batt_Leistung - Leistung pro Ladepunkt [kW]
%   Anzahl_Peaks_Tag  - Anzahl Peaks pro Tag (z.B. 2)
%   peak_hour         - Stunde (0-23) des ersten Peaks (optional, default 9)
%
% Outputs:
%   time_day, P_load, E_total, E_target_reached

if nargin < 5 || isempty(Anzahl_Peaks_Tag), Anzahl_Peaks_Tag = 2; end
if nargin < 6 || isempty(peak_hour), peak_hour = 9; end

T_day = 24 * 3600;
time_day = 0:dt:T_day-dt;
t_norm = time_day / T_day;  % 0..1 normiert

P_max = Anschlusspunkte * LKW_Batt_Leistung;  % [kW]
E_max = P_max * 24;                           % [kWh]
P_avg = Bedarfenergie / 24;                   % [kW]

% Fall: Bedarf größer als maximal erreichbar
if Bedarfenergie >= E_max
    P_load = ones(size(time_day)) * P_max;
    E_target_reached = false;
else
    if P_avg <= 0
        P_load = zeros(size(time_day));
        E_target_reached = true;
    else
        omega = 2*pi*Anzahl_Peaks_Tag;
        k = min(1, (P_max / P_avg) - 1);

        % Phase so, dass erster Peak bei peak_hour liegt
        t_peak_norm = mod(peak_hour/24, 1);
        phi = pi/2 - omega * t_peak_norm;

        % Grundprofil (Sinusform)
        P_load = P_avg * (1 + k * sin(omega * t_norm + phi));

        % numerische Grenzen
        P_load(P_load < 0) = 0;
        P_load(P_load > P_max) = P_max;

        % --- Plateau an Peaks einfügen ---
        plateau_duration = 2 * 3600;  % 2 Stunden in Sekunden
        plateau_samples = round(plateau_duration / dt);

        % Positionen der Peaks im Zeitvektor
        for i = 0:Anzahl_Peaks_Tag-1
            peak_time = (peak_hour + i*(24/Anzahl_Peaks_Tag)) * 3600;
            [~, idx_peak] = min(abs(time_day - peak_time));

            % Bereich für Plateau
            start_idx = max(1, idx_peak - round(plateau_samples/2));
            end_idx   = min(length(time_day), idx_peak + round(plateau_samples/2));

            % Plateau auf P_max setzen
            P_load(start_idx:end_idx) = P_max;
        end
    end
    E_target_reached = true;
end

% Energie am Tag
E_total = trapz(time_day, P_load) / 3600;  % [kWh]
end