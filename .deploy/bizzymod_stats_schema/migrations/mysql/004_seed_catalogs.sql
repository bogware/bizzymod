-- =============================================================================
-- bizzymod-stats — 004_seed_catalogs
-- Populate catalog tables with canonical values. Safe to re-run: uses
-- INSERT IGNORE so manual edits (custom awards, custom weapons) survive.
-- =============================================================================

SET NAMES utf8mb4;

-- Games ----------------------------------------------------------------------
INSERT IGNORE INTO `games` (`id`, `code`, `name`) VALUES
    (0, 'any',     'Any L4D'),
    (1, 'l4d1',    'Left 4 Dead'),
    (2, 'l4d2',    'Left 4 Dead 2');

-- Gamemodes (IDs match legacy plugin GAMEMODE_* defines) ---------------------
INSERT IGNORE INTO `gamemodes` (`id`, `code`, `name`) VALUES
    (0, 'coop',          'Co-op'),
    (1, 'versus',        'Versus'),
    (2, 'realism',       'Realism'),
    (3, 'survival',      'Survival'),
    (4, 'scavenge',      'Scavenge'),
    (5, 'realismversus', 'Realism Versus'),
    (6, 'mutation',      'Mutation'),
    (7, 'holdout',       'Holdout'),
    (8, 'tankrun',       'Tank Run');

-- Difficulties ---------------------------------------------------------------
INSERT IGNORE INTO `difficulties` (`id`, `code`, `name`, `multiplier`) VALUES
    (0, 'unknown', 'Unknown',   1.00),
    (1, 'easy',    'Easy',      0.50),
    (2, 'normal',  'Normal',    1.00),
    (3, 'hard',    'Advanced',  2.00),
    (4, 'impossible', 'Expert', 4.00);

-- Special infected (IDs match legacy INF_ID_* defines for L4D2 where they
-- conflict with L4D1 IDs; L4D1 witch/tank legacy IDs are remapped) ----------
INSERT IGNORE INTO `special_infected` (`id`, `code`, `name`, `game_id`) VALUES
    (1, 'smoker',    'Smoker',    0),
    (2, 'boomer',    'Boomer',    0),
    (3, 'hunter',    'Hunter',    0),
    (4, 'spitter',   'Spitter',   2),
    (5, 'jockey',    'Jockey',    2),
    (6, 'charger',   'Charger',   2),
    (7, 'witch',     'Witch',     0),
    (8, 'tank',      'Tank',      0);

-- Weapons (canonical L4D1/L4D2 weapon entity names). Auto-extended by the
-- plugin on first sight of an unknown weapon; this just preseeds the common
-- ones with friendly display names and slot info. -----------------------------
INSERT IGNORE INTO `weapons` (`code`, `display_name`, `slot`, `game_id`) VALUES
    -- Primary
    ('rifle',              'M16 Assault Rifle',     0, 0),
    ('rifle_ak47',         'AK-47',                 0, 2),
    ('rifle_desert',       'SCAR (Desert Rifle)',   0, 2),
    ('rifle_sg552',        'SG552',                 0, 2),
    ('rifle_m60',          'M60',                   0, 2),
    ('smg',                'Uzi (SMG)',             0, 0),
    ('smg_silenced',       'MAC-10 (Silenced SMG)', 0, 2),
    ('smg_mp5',            'MP5',                   0, 2),
    ('autoshotgun',        'Auto Shotgun',          0, 0),
    ('shotgun_chrome',     'Chrome Shotgun',        0, 2),
    ('shotgun_spas',       'Combat Shotgun (SPAS)', 0, 2),
    ('pumpshotgun',        'Pump Shotgun',          0, 0),
    ('hunting_rifle',      'Hunting Rifle',         0, 0),
    ('sniper_military',    'Military Sniper',       0, 2),
    ('sniper_awp',         'AWP',                   0, 2),
    ('sniper_scout',       'Scout',                 0, 2),
    ('grenade_launcher',   'Grenade Launcher',      0, 2),
    -- Secondary
    ('pistol',             'Pistol',                1, 0),
    ('pistol_magnum',      '.357 Magnum',           1, 2),
    ('chainsaw',           'Chainsaw',              1, 2),
    -- Melee
    ('melee',              'Melee (generic)',       3, 0),
    ('katana',             'Katana',                3, 2),
    ('machete',            'Machete',               3, 2),
    ('crowbar',            'Crowbar',               3, 2),
    ('cricket_bat',        'Cricket Bat',           3, 2),
    ('tonfa',              'Tonfa (Nightstick)',    3, 2),
    ('frying_pan',         'Frying Pan',            3, 2),
    ('baseball_bat',       'Baseball Bat',          3, 2),
    ('electric_guitar',    'Electric Guitar',       3, 2),
    ('fireaxe',            'Fire Axe',              3, 2),
    ('golfclub',           'Golf Club',             3, 2),
    ('knife',              'Knife',                 3, 2),
    ('pitchfork',          'Pitchfork',             3, 2),
    ('shovel',             'Shovel',                3, 2),
    -- Throwable
    ('pipe_bomb',          'Pipe Bomb',             2, 0),
    ('molotov',            'Molotov',               2, 0),
    ('vomitjar',           'Bile Bomb',             2, 2),
    -- Misc / non-weapon damage sources
    ('inferno',            'Fire',                  4, 0),
    ('entityflame',        'Entity Fire',           4, 0),
    ('prop_minigun',       'Mounted Minigun',       4, 0),
    ('tank_claw',          'Tank Claw',             4, 0),
    ('hunter_claw',        'Hunter Claw',           4, 0),
    ('smoker_claw',        'Smoker Claw',           4, 0),
    ('boomer_claw',        'Boomer Claw',           4, 0),
    ('jockey_claw',        'Jockey Claw',           4, 2),
    ('charger_claw',       'Charger Claw',          4, 2),
    ('spitter_claw',       'Spitter Claw',          4, 2),
    ('world',              'World (fall/etc)',      4, 0);

-- Awards: canonical catalog. Replaces the legacy `award_*` columns ----------
INSERT IGNORE INTO `awards` (`code`, `name`, `description`, `category`, `team`, `game_id`, `is_negative`, `display_order`) VALUES
    -- Survivor
    ('witch_crowned',       'Witch Crowner',          'Killed a witch with one shotgun blast',           'survivor', 2, 0, 0, 10),
    ('witch_disturb',       'Disturbed The Witch',    'Caused a witch to startle and attack',           'survivor', 2, 0, 0, 11),
    ('tank_kill',           'Tank Killer',            'Killed a tank',                                  'survivor', 2, 0, 0, 12),
    ('tank_kill_no_deaths', 'Untouched Tank Killer',  'Killed a tank with no survivor deaths',          'survivor', 2, 0, 0, 13),
    ('all_in_safehouse',    'Full House',             'Reached the safe room with all survivors',      'survivor', 2, 0, 0, 14),
    ('let_in_safehouse',    'Door Holder',            'Closed the safe room after the team',           'survivor', 2, 0, 0, 15),
    ('protect',             'Bodyguard',              'Saved a survivor from a SI pin',                 'survivor', 2, 0, 0, 16),
    ('revive',              'Medic',                  'Revived an incapacitated survivor',              'survivor', 2, 0, 0, 17),
    ('rescue',              'Rescuer',                'Rescued a survivor from a closet',               'survivor', 2, 0, 0, 18),
    ('campaign',            'Campaign Champ',         'Finished a campaign finale',                     'finale',   2, 0, 0, 19),
    ('left4dead',           'Left 4 Dead',            'Last survivor standing on a finale',             'finale',   2, 0, 0, 20),
    ('gas_pour',            'Gascan Pourer',          'Poured a gas can on a finale',                   'finale',   2, 2, 0, 21),
    ('ammo_upgrade',        'Ammo Forward',           'Deployed an ammo upgrade pack',                  'survivor', 2, 2, 0, 22),
    ('matador',             'Matador',                'Killed a charging Charger with a melee weapon',  'survivor', 2, 2, 0, 23),
    ('defib',               'Defibrillator Use',      'Revived a dead survivor with a defib',           'survivor', 2, 2, 0, 24),
    ('adrenaline_shared',   'Stimpack',               'Shared adrenaline with a teammate',              'survivor', 2, 2, 0, 25),
    ('pills_shared',        'Pill Pusher',            'Shared pain pills with a teammate',              'survivor', 2, 0, 0, 26),
    ('survivor_down',       'Downed',                 'Was incapacitated by infected',                  'survivor', 2, 1, 0, 90),
    ('ledge_grab',          'Hangin On',              'Caused a survivor to grab a ledge',              'infected', 3, 0, 0, 30),
    -- Infected
    ('pounce_perfect',      'Perfect Pounce',         'Pounce with full damage from height',            'infected', 3, 0, 0, 31),
    ('pounce_nice',         'Nice Pounce',            'Pounce with partial damage from height',        'infected', 3, 0, 0, 32),
    ('boomer_perfect',      'Perfect Vomit',          'Blinded all four survivors with one vomit',     'infected', 3, 0, 0, 33),
    ('bulldozer',           'Bulldozer',              'Did 200+ damage with one tank punch',           'infected', 3, 0, 0, 34),
    ('scattering_ram',      'Scattering Ram',         'Charge impact on 4 survivors',                  'infected', 3, 2, 0, 35),
    ('tank_sniper',         'Tank Sniper',            'Hit a survivor with a thrown rock',             'infected', 3, 0, 0, 36),
    ('infected_win',        'Infected Victory',       'Won a round as infected',                       'infected', 3, 0, 0, 37),
    ('scavenge_infected_win', 'Scavenge Hold',        'Held off survivors in scavenge',                'infected', 3, 2, 0, 38),
    -- Discipline / negative
    ('friendly_fire',       'Friendly Fire',          'Damaged a teammate',                            'ff',       2, 1, 0, 80),
    ('friendly_incap',      'Friendly Incap',         'Incapacitated a teammate',                      'ff',       2, 1, 0, 81),
    ('teamkill',            'Team Kill',              'Killed a teammate',                             'ff',       2, 1, 0, 82),
    -- Special / rare
    ('caralarm_triggered',  'Car Alarm',              'Triggered a car alarm',                         'special',  2, 2, 1, 83);
