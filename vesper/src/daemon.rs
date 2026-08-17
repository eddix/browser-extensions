use crate::config::{Cli, Config};
use crate::error::{Result, VesperError};
use dirs::home_dir;
use std::path::PathBuf;
use std::process::Command;

const LABEL: &str = "com.vesper.plist";
const PLIST_NAME: &str = "com.vesper.plist";

fn launch_agents_dir() -> Result<PathBuf> {
    let home = home_dir()
        .ok_or_else(|| VesperError::Config("Could not find home directory".into()))?;
    Ok(home.join("Library").join("LaunchAgents"))
}

fn plist_path() -> Result<PathBuf> {
    Ok(launch_agents_dir()?.join(PLIST_NAME))
}

fn current_exe() -> Result<PathBuf> {
    std::env::current_exe().map_err(|e| VesperError::Io(e))
}

fn log_dir() -> Result<PathBuf> {
    let dir = Config::config_dir()?.join("logs");
    if !dir.exists() {
        std::fs::create_dir_all(&dir)?;
    }
    Ok(dir)
}

pub fn install(cli: &Cli, vault_path: &PathBuf) -> Result<()> {
    let exe = current_exe()?;
    let plist_path = plist_path()?;
    let log_dir = log_dir()?;

    let stdout_log = log_dir.join("vesper.log");
    let stderr_log = log_dir.join("vesper.error.log");

    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>

    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
        <string>serve</string>
        <string>--vault-path</string>
        <string>{vault}</string>
        <string>--port</string>
        <string>{port}</string>
        <string>--host</string>
        <string>{host}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>{stdout}</string>

    <key>StandardErrorPath</key>
    <string>{stderr}</string>
</dict>
</plist>
"#,
        label = LABEL,
        exe = exe.display(),
        vault = vault_path.display(),
        port = cli.port,
        host = cli.host,
        stdout = stdout_log.display(),
        stderr = stderr_log.display(),
    );

    let launch_agents = launch_agents_dir()?;
    if !launch_agents.exists() {
        std::fs::create_dir_all(&launch_agents)?;
    }

    std::fs::write(&plist_path, &plist)?;
    println!("Written plist to {:?}", plist_path);

    // 如果已经加载过，先 unload
    let _ = Command::new("launchctl")
        .args(["unload", plist_path.to_str().unwrap()])
        .output();

    let output = Command::new("launchctl")
        .args(["load", "-w", plist_path.to_str().unwrap()])
        .output()?;

    if output.status.success() {
        println!("Service installed and started.");
        println!("Logs: {:?}", log_dir);
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(VesperError::Config(format!(
            "launchctl load failed: {}",
            stderr
        )));
    }

    Ok(())
}

pub fn uninstall() -> Result<()> {
    let plist_path = plist_path()?;

    if !plist_path.exists() {
        println!("Service is not installed.");
        return Ok(());
    }

    let output = Command::new("launchctl")
        .args(["unload", "-w", plist_path.to_str().unwrap()])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        eprintln!("Warning: launchctl unload failed: {}", stderr);
    }

    std::fs::remove_file(&plist_path)?;
    println!("Service uninstalled.");

    Ok(())
}

pub fn status() -> Result<()> {
    let plist_path = plist_path()?;

    if !plist_path.exists() {
        println!("Status: not installed");
        return Ok(());
    }

    println!("Plist: {:?}", plist_path);

    let output = Command::new("launchctl")
        .args(["list", LABEL])
        .output()?;

    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        // launchctl list 输出里 "PID" 那行有值说明正在运行
        let running = stdout.lines().any(|l| {
            l.trim_start().starts_with("\"PID\"") && !l.contains("0,")
        });
        if running {
            println!("Status: running");
        } else {
            println!("Status: stopped (registered but not running)");
        }
        println!("{}", stdout.trim());
    } else {
        println!("Status: not running");
    }

    if let Ok(log_dir) = log_dir() {
        println!("Logs: {:?}", log_dir);
    }

    Ok(())
}
