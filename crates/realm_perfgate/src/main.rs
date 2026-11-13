//! realm_perfgate <budgets.toml> <report.json> [--report-only]
//!
//! The report is the JSON a probe writes on the reference machine:
//! `{"gpu": "...", "phases": [{"phase": "idle", "p95_ms": 14.2, ...}], "memory": {"total_mb": 2100}}`.
//! Each budget rule names a metric and a ceiling. Phase metrics are checked in
//! every listed phase (all phases when the rule lists none); `memory.*` rules
//! read the top-level memory block. A metric missing from the report fails the
//! gate, so a probe that stops measuring something cannot pass silently.
//! `--report-only` prints the same table and always exits 0 (baselines).

use std::process::ExitCode;

use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct Budgets {
    reference: Reference,
    #[serde(rename = "rule")]
    rules: Vec<Rule>,
}

#[derive(Deserialize)]
struct Reference {
    name: String,
}

#[derive(Deserialize)]
struct Rule {
    metric: String,
    max: f64,
    #[serde(default)]
    phases: Vec<String>,
    why: String,
}

struct Row {
    metric: String,
    scope: String,
    value: Option<f64>,
    max: f64,
}

impl Row {
    fn passed(&self) -> bool {
        self.value.is_some_and(|value| value <= self.max)
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let report_only = args.iter().any(|a| a == "--report-only");
    let paths: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let [budgets_path, report_path] = paths.as_slice() else {
        eprintln!("usage: realm_perfgate <budgets.toml> <report.json> [--report-only]");
        return ExitCode::from(2);
    };
    match run(budgets_path, report_path) {
        Ok((budgets, report, rows)) => print_and_judge(&budgets, &report, &rows, report_only),
        Err(error) => {
            eprintln!("perfgate: {error}");
            ExitCode::from(2)
        }
    }
}

fn run(budgets_path: &str, report_path: &str) -> Result<(Budgets, Value, Vec<Row>), String> {
    let budgets_text =
        std::fs::read_to_string(budgets_path).map_err(|e| format!("{budgets_path}: {e}"))?;
    let budgets: Budgets =
        toml::from_str(&budgets_text).map_err(|e| format!("{budgets_path}: {e}"))?;
    let report_text =
        std::fs::read_to_string(report_path).map_err(|e| format!("{report_path}: {e}"))?;
    let report: Value =
        serde_json::from_str(&report_text).map_err(|e| format!("{report_path}: {e}"))?;
    let phases = report["phases"].as_array().cloned().unwrap_or_default();

    let mut rows = Vec::new();
    for rule in &budgets.rules {
        if let Some(key) = rule.metric.strip_prefix("memory.") {
            rows.push(Row {
                metric: rule.metric.clone(),
                scope: "process".to_owned(),
                value: report["memory"][key].as_f64(),
                max: rule.max,
            });
            continue;
        }
        let wanted: Vec<&str> = if rule.phases.is_empty() {
            phases.iter().filter_map(|p| p["phase"].as_str()).collect()
        } else {
            rule.phases.iter().map(String::as_str).collect()
        };
        for name in wanted {
            let phase = phases.iter().find(|p| p["phase"].as_str() == Some(name));
            rows.push(Row {
                metric: rule.metric.clone(),
                scope: name.to_owned(),
                value: phase.and_then(|p| p[rule.metric.as_str()].as_f64()),
                max: rule.max,
            });
        }
    }
    Ok((budgets, report, rows))
}

fn print_and_judge(budgets: &Budgets, report: &Value, rows: &[Row], report_only: bool) -> ExitCode {
    println!(
        "reference: {}   gpu: {}",
        budgets.reference.name,
        report["gpu"].as_str().unwrap_or("unknown")
    );
    println!(
        "{:<6} {:<18} {:<8} {:>12} {:>12}",
        "", "metric", "scope", "value", "budget"
    );
    for row in rows {
        let verdict = if row.passed() { "ok" } else { "OVER" };
        let value = row
            .value
            .map_or_else(|| "missing".to_owned(), |v| format!("{v:.2}"));
        println!(
            "{verdict:<6} {:<18} {:<8} {value:>12} {:>12.2}",
            row.metric, row.scope, row.max
        );
    }
    let failed: Vec<&Row> = rows.iter().filter(|r| !r.passed()).collect();
    for rule in &budgets.rules {
        if failed.iter().any(|row| row.metric == rule.metric) {
            println!("  {} -> {}", rule.metric, rule.why);
        }
    }
    println!(
        "{} of {} checks within budget",
        rows.len() - failed.len(),
        rows.len()
    );
    if failed.is_empty() || report_only {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
