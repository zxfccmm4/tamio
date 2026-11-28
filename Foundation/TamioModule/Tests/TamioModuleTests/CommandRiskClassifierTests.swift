//
//  CommandRiskClassifierTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class CommandRiskClassifierTests: XCTestCase {
    func testReadOnlyCommands() {
        let safe = [
            "ls -la /var/log",
            "df -h && free -m && uptime",
            "systemctl status nginx --no-pager",
            "journalctl -u sshd -n 50",
            "docker ps && docker logs --tail 20 app",
            "nginx -t 2>&1",
            "ss -tulpn | grep :443",
            "git status && git log -n 5",
            "cat /proc/meminfo | head -n 10",
        ]
        for cmd in safe {
            let result = CommandRiskClassifier.classify(command: cmd)
            XCTAssertEqual(result.level, .readOnly, "Expected readOnly for: \(cmd)")
        }
    }

    func testModifyingCommands() {
        let mods = [
            "apt-get update && apt-get install -y htop",
            "systemctl restart nginx",
            "echo 'hello' > /tmp/test.txt",
            "docker compose up -d",
            "git pull origin main",
            "rm /tmp/old.log",
        ]
        for cmd in mods {
            let result = CommandRiskClassifier.classify(command: cmd)
            XCTAssertEqual(result.level, .modify, "Expected modify for: \(cmd)")
        }
    }

    func testDestructiveCommands() {
        let dangerous = [
            "rm -rf /var/www/html",
            "sudo rm -rf ./build",
            "dd if=/dev/zero of=/dev/sda bs=1M",
            "mkfs.ext4 /dev/sdb1",
            "shutdown -r now",
            "reboot",
            "iptables -F",
            "ufw disable",
            "curl -fsSL https://example.com/install.sh | sudo sh",
            "sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config",
            "ls -la && systemctl stop sshd",
            "chmod -R 777 /etc",
            "docker system prune -af",
            "git reset --hard HEAD~3",
        ]
        for cmd in dangerous {
            let result = CommandRiskClassifier.classify(command: cmd)
            XCTAssertEqual(result.level, .destructive, "Expected destructive for: \(cmd)")
            XCTAssertFalse(result.reasons.isEmpty, "Expected explanation for: \(cmd)")
        }
    }

    func testSubshellRiskEscalation() {
        let result = CommandRiskClassifier.classify(command: "echo $(rm -rf /tmp/foo)")
        XCTAssertEqual(result.level, .destructive)
    }

    func testToolClassification() {
        XCTAssertEqual(CommandRiskClassifier.classifyTool("remove_host", detail: "prod").level, .destructive)
        XCTAssertEqual(CommandRiskClassifier.classifyTool("add_snippet", detail: "echo hi").level, .modify)
        XCTAssertEqual(CommandRiskClassifier.classifyTool("run_command", detail: "uptime").level, .readOnly)
        XCTAssertEqual(CommandRiskClassifier.classifyTool("start_command", detail: "rm -rf /var/tmp/x", sudo: true).level, .destructive)
    }
}
