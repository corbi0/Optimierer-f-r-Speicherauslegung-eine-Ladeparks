function deg = bess_degradation(p, years)
% Sehr einfache Degradations-/Ersatzlogik für BESS
% p: Parameter (siehe Defaults); years: Betrachtungszeitraum (Jahre)

% Defaults
p = set_default(p, 'calendar_fade_per_year', 0.01);   % 1 %% Kapazitätsverlust pro Jahr 
p = set_default(p, 'cycle_fade_per_EFC',     1e-5);   % 0.001 %% Verlust je Vollzyklus (≈5 %% nach 1000 EFC)
p = set_default(p, 'efc_per_year',           300);    % Vollzyklen/Jahr Eine komplette Ladung + Entladung
p = set_default(p, 'EoL_frac',               0.80);   % End of Life 80 %% Restkapazität

cap = ones(1, years+1);
cap(1) = 1.0;
for y = 1:years
    cyc_fade_y = p.efc_per_year * p.cycle_fade_per_EFC;
    % Kalenderfade multiplicativ, Zyklenfade additiv (einfaches, robustes Modell)
    cap(y+1)   = cap(y) * (1 - p.calendar_fade_per_year) - cyc_fade_y;
end

replacement_year = find(cap <= p.EoL_frac, 1, 'first') - 1; % Jahr, in dem EoL erstmals erreicht wird

deg = struct('cap_frac_by_year', cap, 'replacement_year', replacement_year, ...
             'params', p);
end

% ---- lokale Hilfsfunktion ----
function p = set_default(p, field, val)
if ~isfield(p, field) || isempty(p.(field))
    p.(field) = val;
end
end
