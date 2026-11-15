"""Walks the quest chain (content/data/quests.json) the way the server runs it
and reports every dead end: a point where a character has claimed every quest
open to it and the next one waits for a level it has not reached.

    python tools/quests/quest_flow.py [content/data] [--kills] [--trace]

The server's rules, mirrored from realm_rules:
- progress.rs exp_threshold: pack_exp(L) x (kills_base + kills_per_level x
  (L - 1)), rounded to 10 (pack_exp = round(exp_base + exp_per_level x L +
  exp_per_level_sq x L^2), spawn_tables pack_tuning; combat.json exp_curve).
- quests.rs is_open / event / claim_quest: a quest opens at its level once
  every quest in `requires` is claimed; an event advances every open quest it
  matches; a claim pays reward_exp through grant_exp (several levels at once).

Two walks (--kills runs only the second):
- quests alone: only reward_exp counts (talks, equips, dummies give none).
- quests + kills: every kill a kill quest
  needs pays the server's per-kill experience (realm_server sim/rewards.rs:
  creature_exp(species, level) x the level gap band; a boss its
  boss_overrides exp_reward, a Dark Shard its monolith type's). The kill is
  counted low: of the weakest pack of that species that still pays a
  character of its level full experience (mobs.json level_gap: the band
  with exp 1.0 starts at 5 levels below), else of the nearest pack;
  creatures only met in dungeons at the quest's level. One kill advances every
  open quest it matches, as on the server. No exp bonus, no party, no elites,
  no grinding beyond what the quests ask, no dungeon kill experience.

A dead end with kills counted means a character who does everything the
quests ask still runs out of quests. Exit code 1 when that walk finds one.
"""
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')


def load(data, name):
    with open(os.path.join(data, name), encoding='utf-8') as f:
        return json.load(f)


def round_half_up(x):
    return int(x + 0.5)


class Rules:
    def __init__(self, data):
        combat = load(data, 'combat.json')
        spawns = load(data, 'spawn_tables.json')
        mobs = load(data, 'mobs.json')
        t = spawns['pack_tuning']
        curve = combat['base_stats']['exp_curve']
        self.exp_base = float(t.get('exp_base', 20))
        self.exp_per_level = float(t.get('exp_per_level', 8))
        self.exp_per_level_sq = float(t.get('exp_per_level_sq', 0))
        self.kills_base = float(curve.get('kills_base', 10))
        self.kills_per_level = float(curve.get('kills_per_level', 10))
        self.max_level = int(combat['limits'].get('max_level', 100))
        self.gap = sorted(mobs['level_gap']['bands'], key=lambda b: -b['min_diff'])
        self.elite_mult = float(mobs['elite'].get('exp_mult', 1))
        self.exp_mult = {k: float(v.get('exp_mult', 1.0)) for k, v in mobs['mobs'].items()}
        self.bosses = {k: v.get('exp_reward', 0) for k, v in spawns['boss_overrides'].items()
                       if isinstance(v, dict)}
        self.stones = {k: v.get('exp_reward', 0) for k, v in spawns['monolith_types'].items()
                       if isinstance(v, dict)}
        # species -> [(level, map)] of ordinary packs; species -> boss exp.
        self.packs = {}
        self.boss_exp = {}
        for p in spawns['packs']:
            if p.get('boss'):
                key = p.get('boss_key') or ('commander' if p.get('commander') else 'matriarch')
                self.boss_exp.setdefault(p['mob'], self.bosses.get(key, 0))
            else:
                self.packs.setdefault(p['mob'], []).append(p['level'])
        for d in load(data, 'dungeons.json')['dungeons'].values():
            for step in d.get('steps', []):
                for s in step.get('spawn', []):
                    if s.get('boss_key'):
                        self.boss_exp.setdefault(s['mob'], self.bosses.get(s['boss_key'], 0))

    def pack_exp(self, level):
        lv = float(level)
        return float(round_half_up(self.exp_base + self.exp_per_level * lv + self.exp_per_level_sq * lv * lv))

    def threshold(self, level):
        lv = max(1, level)
        kills = self.kills_base + self.kills_per_level * (lv - 1)
        return round_half_up(self.pack_exp(lv) * kills / 10.0) * 10

    def creature_exp(self, species, level):
        return int(self.pack_exp(level) * self.exp_mult.get(species, 1.0))

    def gap_exp(self, mob_level, player_level):
        diff = mob_level - player_level
        for b in self.gap:
            if diff >= b['min_diff']:
                return float(b['exp'])
        return 1.0

    def kill_exp(self, q, player_level):
        """One kill toward quest q: (exp, creature level)."""
        kind, species = q['type'], q.get('target', '')
        if kind == 'monolith':
            return self.stones.get('dark', 0), 0
        if q.get('boss'):
            return self.boss_exp.get(species, 0), 0
        levels = self.packs.get(species)
        if not levels:
            mob_level = q['level']
        else:
            full = [lv for lv in levels if self.gap_exp(lv, player_level) >= 1.0]
            mob_level = min(full) if full else max(levels)
        base = round_half_up(self.creature_exp(species, mob_level) * self.gap_exp(mob_level, player_level))
        return base, mob_level


class Walk:
    def __init__(self, rules, chain, kills, trace=False):
        self.r = rules
        self.chain = chain
        self.kills = kills
        self.trace = trace
        self.level, self.exp = 1, 0
        self.done, self.ready, self.progress = [], [], {}
        self.kill_total = 0
        self.dead_ends = []

    def is_open(self, q):
        return (q['level'] <= self.level and q['id'] not in self.done and q['id'] not in self.ready
                and all(r in self.done for r in q.get('requires', [])))

    def grant(self, amount):
        self.exp += amount
        while self.level < self.r.max_level and self.exp >= self.r.threshold(self.level):
            self.exp -= self.r.threshold(self.level)
            self.level += 1

    def event(self, kind, target, boss):
        for q in self.chain:
            if (q['type'] != kind or (q.get('boss') and not boss)
                    or (q.get('target') and q['target'] != target) or not self.is_open(q)):
                continue
            n = self.progress.get(q['id'], 0) + 1
            if n >= max(1, q.get('count', 1)):
                self.progress.pop(q['id'], None)
                self.ready.append(q['id'])
            else:
                self.progress[q['id']] = n

    def act(self, q):
        """One step toward quest q: one kill, one talk, one hit..."""
        if q['type'] in ('kill', 'monolith'):
            exp, _ = self.r.kill_exp(q, self.level)
            self.event(q['type'], q.get('target', ''), bool(q.get('boss')))
            if self.kills:
                self.kill_total += exp
                self.grant(exp)
        else:
            self.event(q['type'], q.get('target', ''), False)

    def claim(self, qid):
        q = next(q for q in self.chain if q['id'] == qid)
        self.ready.remove(qid)
        self.done.append(qid)
        before = self.level
        self.grant(q.get('reward_exp', 0))
        if self.trace:
            print('  claim %s (L%d %-8s) +%5d  -> level %d  %d/%d%s' % (
                qid, q['level'], q['type'], q.get('reward_exp', 0), self.level, self.exp,
                self.r.threshold(self.level), '  LEVEL UP' if self.level > before else ''))

    def run(self):
        chain = self.chain
        while len(self.done) < len(chain):
            if self.ready:
                self.claim(self.ready[0])
                continue
            open_q = [q for q in chain if self.is_open(q)]
            if open_q:
                self.act(open_q[0])
                continue
            nxt = min((q for q in chain if q['id'] not in self.done),
                      key=lambda q: (q['level'], chain.index(q)))
            need = self.r.threshold(self.level) - self.exp
            per, mob = self.r.kill_exp({'type': 'kill', 'target': self._near_species(nxt), 'level': nxt['level']},
                                       self.level)
            self.dead_ends.append((nxt['id'], self.level, nxt['level'], self.exp,
                                   self.r.threshold(self.level), need, per))
            # Carry on as a player who grinds to the next level would.
            self.grant(need)
        return self

    def _near_species(self, q):
        """The species a stuck player would hunt: the last kill target before q."""
        idx = self.chain.index(q)
        for p in reversed(self.chain[:idx]):
            if p['type'] == 'kill' and not p.get('boss'):
                return p['target']
        return 'black_weaver'


def report(rules, chain, kills, trace):
    w = Walk(rules, chain, kills, trace).run()
    label = 'quests + the kills they ask for' if kills else 'quest rewards alone'
    print('== %s: %d dead end(s); level %d at the end (%d/%d exp)%s' % (
        label, len(w.dead_ends), w.level, w.exp, rules.threshold(w.level),
        ', %d exp from kills' % w.kill_total if kills else ''))
    for qid, have, need_level, exp, thr, short, per in w.dead_ends:
        print('   %s needs level %d, reached %d (%d/%d exp, %d short = ~%d kills of %d exp)' % (
            qid, need_level, have, exp, thr, short, -(-short // max(1, per)), per))
    return w


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    data = args[0] if args else os.path.join(ROOT, 'content', 'data')
    rules = Rules(data)
    chain = load(data, 'quests.json')['chain']
    trace = '--trace' in argv
    if '--kills' not in argv:
        report(rules, chain, False, trace)
    w = report(rules, chain, True, trace)
    return 1 if w.dead_ends else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
