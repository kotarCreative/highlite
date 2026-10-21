use std::env;
use std::error::Error;
use std::io::{self, Read, Write};

use highlite_compiler::{CompileInput, ScrawlExportOptions, compile_capture, to_scrawl_bundle};

const USAGE: &str = "\
highlite-compiler — compile a Highlite capture

Usage:
  highlite-compiler compile [--pretty] < input.json > bundle.json
  highlite-compiler scrawl  [--pretty] < input.json > scrawl.json

Input is a CompileInput object. Output is JSON on stdout.
";

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{USAGE}");
        return Ok(());
    }

    let command = args
        .iter()
        .find(|arg| !arg.starts_with('-'))
        .map_or("compile", String::as_str);
    let pretty = args.iter().any(|arg| arg == "--pretty");

    if !matches!(command, "compile" | "scrawl") {
        return Err(format!("unknown command: {command}\n\n{USAGE}").into());
    }

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let request: CompileInput = serde_json::from_str(&input)?;
    let compiled = compile_capture(&request);

    let output = match command {
        "scrawl" => serde_json::to_value(to_scrawl_bundle(
            &compiled,
            &ScrawlExportOptions::default(),
        )?)?,
        _ => serde_json::to_value(&compiled)?,
    };

    let rendered = if pretty {
        serde_json::to_string_pretty(&output)?
    } else {
        serde_json::to_string(&output)?
    };
    let mut stdout = io::stdout().lock();
    stdout.write_all(rendered.as_bytes())?;
    stdout.write_all(b"\n")?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
