using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WSLPerfMonitor
{
    static class Theme
    {
        public static readonly Color BgDark = Color.FromArgb(30, 30, 30);
        public static readonly Color BgPanel = Color.FromArgb(45, 45, 48);
        public static readonly Color BgControl = Color.FromArgb(51, 51, 55);
        public static readonly Color Border = Color.FromArgb(67, 67, 70);
        public static readonly Color FgText = Color.FromArgb(241, 241, 241);
        public static readonly Color FgDim = Color.FromArgb(153, 153, 153);
        public static readonly Color Accent = Color.FromArgb(0, 122, 204);
        public static readonly Color ErrorBg = Color.FromArgb(70, 28, 28);
        public static readonly Color WarningBg = Color.FromArgb(70, 58, 18);
        public static readonly Color OkBg = Color.FromArgb(22, 55, 22);
        public static readonly Color Danger = Color.FromArgb(200, 50, 50);

        public static void StyleButton(Button btn, Color? bg = null)
        {
            btn.FlatStyle = FlatStyle.Flat;
            btn.BackColor = bg ?? BgControl;
            btn.ForeColor = FgText;
            btn.FlatAppearance.BorderColor = Border;
            btn.Cursor = Cursors.Hand;
        }

        public static string FormatBytes(long bytes)
        {
            if (bytes <= 0) return "-";
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F0} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F1} GB";
        }
    }

    public class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            using var mutex = new Mutex(true, "WSLPerfMonitor_SingleInstance", out bool createdNew);
            if (!createdNew)
            {
                MessageBox.Show("WSL Performance Monitor is already running.", "WSL Perf Monitor",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            Application.Run(new TrayApplicationContext());
        }
    }

    public class TrayApplicationContext : ApplicationContext
    {
        private readonly NotifyIcon _trayIcon;
        private readonly ContextMenuStrip _contextMenu;
        private readonly System.Windows.Forms.Timer _monitorTimer;
        private readonly WSLMonitor _monitor;
        private bool _warningsEnabled = true;
        private DateTime _lastWarning = DateTime.MinValue;
        private readonly TimeSpan _warningCooldown = TimeSpan.FromSeconds(30);
        private DashboardForm? _dashboardForm;
        private ScanResultsForm? _scanResultsForm;

        public TrayApplicationContext()
        {
            _monitor = new WSLMonitor();

            _contextMenu = new ContextMenuStrip();
            _contextMenu.Items.Add("Scan Now", null, OnScanNow);
            _contextMenu.Items.Add("Open Dashboard", null, OnOpenDashboard);
            _contextMenu.Items.Add("-");
            _contextMenu.Items.Add("Migrate Project...", null, OnMigrateProject);
            _contextMenu.Items.Add("New Fast Project...", null, OnNewProject);
            _contextMenu.Items.Add("-");
            var warningsItem = new ToolStripMenuItem("Enable Warnings", null, OnToggleWarnings) { Checked = true };
            _contextMenu.Items.Add(warningsItem);
            _contextMenu.Items.Add("Settings...", null, OnSettings);
            _contextMenu.Items.Add("-");
            _contextMenu.Items.Add("Exit", null, OnExit);

            _trayIcon = new NotifyIcon
            {
                Icon = CreateIcon(Color.Green),
                Text = "WSL Performance Monitor\nStatus: OK",
                ContextMenuStrip = _contextMenu,
                Visible = true
            };
            _trayIcon.DoubleClick += OnOpenDashboard;

            _monitorTimer = new System.Windows.Forms.Timer { Interval = 5000 };
            _monitorTimer.Tick += OnMonitorTick;
            _monitorTimer.Start();

            Task.Run(() => PerformScan(showNotification: false));
        }

        private Icon CreateIcon(Color color)
        {
            var bitmap = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using var brush = new SolidBrush(color);
                using var font = new Font("Segoe UI", 10, FontStyle.Bold);
                g.DrawString("W", font, brush, -1, 0);
            }
            return Icon.FromHandle(bitmap.GetHicon());
        }

        private async void OnMonitorTick(object sender, EventArgs e)
        {
            await Task.Run(() => PerformScan(showNotification: _warningsEnabled));
        }

        private void PerformScan(bool showNotification)
        {
            try
            {
                var issues = _monitor.Scan();

                if (issues.Any(i => i.Severity == IssueSeverity.Error))
                    UpdateIcon(Color.Red, $"WSL Performance Monitor\n{issues.Count} issues detected");
                else if (issues.Any(i => i.Severity == IssueSeverity.Warning))
                    UpdateIcon(Color.Orange, $"WSL Performance Monitor\n{issues.Count} warnings");
                else
                    UpdateIcon(Color.Green, "WSL Performance Monitor\nStatus: OK");

                if (showNotification && issues.Any() && DateTime.Now - _lastWarning > _warningCooldown)
                {
                    var topIssue = issues.OrderByDescending(i => i.Severity).First();
                    ShowBalloon(topIssue);
                    _lastWarning = DateTime.Now;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Scan error: {ex.Message}");
            }
        }

        private void UpdateIcon(Color color, string tooltip)
        {
            if (_trayIcon.Icon != null)
            {
                var oldIcon = _trayIcon.Icon;
                _trayIcon.Icon = CreateIcon(color);
                oldIcon.Dispose();
            }
            _trayIcon.Text = tooltip.Length > 63 ? tooltip.Substring(0, 63) : tooltip;
        }

        private void ShowBalloon(PerformanceIssue issue)
        {
            _trayIcon.ShowBalloonTip(5000, "WSL Performance Warning",
                $"{issue.Message}\n\nClick for suggestions.",
                issue.Severity == IssueSeverity.Error ? ToolTipIcon.Error : ToolTipIcon.Warning);
        }

        private void OnScanNow(object sender, EventArgs e)
        {
            if (_scanResultsForm == null || _scanResultsForm.IsDisposed)
            {
                _scanResultsForm = new ScanResultsForm(_monitor);
                _scanResultsForm.Show();
            }
            else
            {
                _scanResultsForm.BringToFront();
                _scanResultsForm.Activate();
            }
        }

        private void OnOpenDashboard(object sender, EventArgs e)
        {
            if (_dashboardForm == null || _dashboardForm.IsDisposed)
            {
                _dashboardForm = new DashboardForm(_monitor);
                _dashboardForm.Show();
            }
            else
            {
                _dashboardForm.BringToFront();
                _dashboardForm.Activate();
            }
        }

        private void OnMigrateProject(object sender, EventArgs e)
        {
            using var dialog = new FolderBrowserDialog
            {
                Description = "Select a project folder on C:\\ to migrate to WSL",
                ShowNewFolderButton = false
            };

            if (dialog.ShowDialog() == DialogResult.OK)
            {
                var projectPath = dialog.SelectedPath;
                var projectName = Path.GetFileName(projectPath);
                var result = MessageBox.Show(
                    $"Migrate '{projectName}' to WSL Linux filesystem?\n\n" +
                    $"From: {projectPath}\nTo: ~/projects/{projectName}\n\n" +
                    "This will copy the project and create a symlink back to Windows.",
                    "Migrate Project", MessageBoxButtons.YesNo, MessageBoxIcon.Question);

                if (result == DialogResult.Yes)
                    MigrateProject(projectPath, projectName);
            }
        }

        private void MigrateProject(string sourcePath, string projectName)
        {
            try
            {
                var destPath = $"~/projects/{projectName}";
                var command = $"mkdir -p ~/projects && cp -r \"{ToWslPath(sourcePath)}\" {destPath} && " +
                             $"ln -sf {destPath} \"/mnt/c/Users/{Environment.UserName}/wsl-projects/{projectName}\"";
                RunWslCommand(command);
                MessageBox.Show(
                    $"Project migrated successfully!\n\nLocation: {destPath}\n" +
                    $"Windows access: C:\\Users\\{Environment.UserName}\\wsl-projects\\{projectName}",
                    "Migration Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Migration failed: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OnNewProject(object sender, EventArgs e)
        {
            using var form = new NewProjectForm();
            if (form.ShowDialog() == DialogResult.OK)
                CreateNewProject(form.ProjectName, form.Template);
        }

        private void CreateNewProject(string name, string template)
        {
            try
            {
                var command = template switch
                {
                    "node" => $"mkdir -p ~/projects/{name} && cd ~/projects/{name} && " +
                             "echo '{{\"name\":\"{name}\",\"version\":\"1.0.0\"}}' > package.json",
                    "python" => $"mkdir -p ~/projects/{name} && cd ~/projects/{name} && python3 -m venv .venv",
                    "rust" => $"cd ~/projects && cargo new {name}",
                    "git" => $"mkdir -p ~/projects/{name} && cd ~/projects/{name} && git init",
                    _ => $"mkdir -p ~/projects/{name}"
                };

                command += $" && mkdir -p /mnt/c/Users/{Environment.UserName}/wsl-projects && " +
                          $"ln -sf ~/projects/{name} /mnt/c/Users/{Environment.UserName}/wsl-projects/{name}";
                RunWslCommand(command);

                var result = MessageBox.Show(
                    $"Project created at ~/projects/{name}\n\nOpen in VS Code?",
                    "Project Created", MessageBoxButtons.YesNo, MessageBoxIcon.Information);

                if (result == DialogResult.Yes)
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "code",
                        Arguments = $"--remote wsl+Ubuntu ~/projects/{name}",
                        UseShellExecute = true
                    });
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to create project: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OnToggleWarnings(object sender, EventArgs e)
        {
            _warningsEnabled = !_warningsEnabled;
            if (sender is ToolStripMenuItem item)
                item.Checked = _warningsEnabled;
        }

        private void OnSettings(object sender, EventArgs e)
        {
            MessageBox.Show("Settings coming soon!", "Settings", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void OnExit(object sender, EventArgs e)
        {
            _monitorTimer.Stop();
            _trayIcon.Visible = false;
            Application.Exit();
        }

        private string ToWslPath(string windowsPath)
        {
            if (windowsPath.Length >= 2 && windowsPath[1] == ':')
            {
                var drive = char.ToLower(windowsPath[0]);
                var rest = windowsPath.Substring(2).Replace('\\', '/');
                return $"/mnt/{drive}{rest}";
            }
            return windowsPath.Replace('\\', '/');
        }

        private void RunWslCommand(string command)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "wsl",
                Arguments = $"-e bash -c \"{command.Replace("\"", "\\\"")}\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            process?.WaitForExit(30000);

            if (process?.ExitCode != 0)
            {
                var error = process?.StandardError.ReadToEnd();
                throw new Exception(error ?? "Unknown error");
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _monitorTimer?.Dispose();
                _trayIcon?.Dispose();
                _contextMenu?.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    public enum IssueSeverity { Info, Warning, Error }

    public class PerformanceIssue
    {
        public IssueSeverity Severity { get; set; }
        public string Message { get; set; }
        public string Details { get; set; }
        public string Suggestion { get; set; }
        public string Process { get; set; }
        public string Path { get; set; }
        public string Pid { get; set; }
        public List<string> Pids { get; set; } = new();
        public long IoReadBytes { get; set; }
        public long IoWriteBytes { get; set; }
        public int Count { get; set; } = 1;
        public bool IsZombie { get; set; }
    }

    public class WSLMonitor
    {
        public List<PerformanceIssue> Scan()
        {
            var issues = new List<PerformanceIssue>();
            try
            {
                issues.AddRange(CheckWslProcesses());
                issues.AddRange(CheckSlowPatterns());
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Scan error: {ex.Message}");
            }
            return issues;
        }

        private List<PerformanceIssue> CheckWslProcesses()
        {
            var issues = new List<PerformanceIssue>();

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl",
                    Arguments = "-e bash -c \"for pid in $(pgrep -x 'bash|zsh|node|npm|git|python|cargo|rustc|gcc|g++|make' 2>/dev/null | head -20); do " +
                               "cwd=$(readlink /proc/$pid/cwd 2>/dev/null); " +
                               "[ -z \\\"$cwd\\\" ] && continue; " +
                               "read cmd etimes pcpu pmem stat tty rss ppid < <(ps -p $pid -o comm=,etimes=,pcpu=,pmem=,stat=,tty=,rss=,ppid= --no-headers 2>/dev/null); " +
                               "start=$(ps -p $pid -o lstart= --no-headers 2>/dev/null); " +
                               "cmdline=$(tr '\\\\0' ' ' < /proc/$pid/cmdline 2>/dev/null | head -c 200); " +
                               "ior=$(awk '/^read_bytes:/{print $2}' /proc/$pid/io 2>/dev/null); " +
                               "iow=$(awk '/^write_bytes:/{print $2}' /proc/$pid/io 2>/dev/null); " +
                               "echo \\\"$pid|$cmd|$etimes|$pcpu|$pmem|$stat|$tty|$rss|$ppid|$start|$cwd|$cmdline|${ior:-0}|${iow:-0}\\\"; done\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                var output = process?.StandardOutput.ReadToEnd() ?? "";
                process?.WaitForExit(5000);

                foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        var parts = line.Split('|');
                        if (parts.Length < 11) continue;

                        var pid = parts[0].Trim();
                        var cmd = parts[1].Trim();
                        int.TryParse(parts[2].Trim(), out int elapsedSeconds);
                        var cpuStr = parts[3].Trim();
                        var memStr = parts[4].Trim();
                        var state = parts[5].Trim();
                        var tty = parts[6].Trim();
                        int.TryParse(parts[7].Trim(), out int rssKb);
                        var ppid = parts[8].Trim();
                        var startTime = parts[9].Trim();
                        var cwd = parts[10].Trim();
                        var cmdline = parts.Length > 11 ? parts[11].Trim() : "";

                        long ioRead = 0, ioWrite = 0;
                        if (parts.Length > 12) long.TryParse(parts[12].Trim(), out ioRead);
                        if (parts.Length > 13) long.TryParse(parts[13].Trim(), out ioWrite);

                        if (!IsSlowPath(cwd)) continue;

                        bool isVSCode = cwd.Contains("Microsoft VS Code") ||
                                       cwd.Contains("vscode") ||
                                       cmdline.Contains(".vscode-server") ||
                                       cmdline.Contains("ms-vscode");

                        if (isVSCode) continue;

                        var elapsed = TimeSpan.FromSeconds(elapsedSeconds);

                        bool isActuallyStuck = state.Contains("D") || state.Contains("Z");
                        bool isSuspiciousLongRunning = elapsedSeconds > 300 && (
                                       cmdline.Contains("benchmark") ||
                                       cmdline.Contains("test") ||
                                       cmdline.Contains("batch") ||
                                       cmdline.Contains("LD_PRELOAD") ||
                                       cmdline.Contains("intensive") ||
                                       cmdline.Contains("validate"));
                        bool isZombie = isActuallyStuck || isSuspiciousLongRunning;

                        string elapsedDisplay = elapsed.TotalHours >= 1
                            ? $"{(int)elapsed.TotalHours}h {elapsed.Minutes}m"
                            : elapsed.TotalMinutes >= 1
                                ? $"{elapsed.Minutes}m {elapsed.Seconds}s"
                                : $"{elapsed.Seconds}s";

                        string memDisplay = rssKb > 1024 ? $"{rssKb / 1024}MB" : $"{rssKb}KB";

                        string stateDesc = state switch
                        {
                            var s when s.StartsWith("S") => "sleeping",
                            var s when s.StartsWith("R") => "running",
                            var s when s.StartsWith("D") => "STUCK (I/O)",
                            var s when s.StartsWith("Z") => "ZOMBIE",
                            var s when s.StartsWith("T") => "stopped",
                            _ => state
                        };

                        var details = $"PID: {pid} | PPID: {ppid} | State: {stateDesc}\n" +
                                     $"CPU: {cpuStr}% | Mem: {memDisplay} ({memStr}%) | TTY: {tty}\n" +
                                     $"Started: {startTime}\nCWD: {cwd}";

                        if (!string.IsNullOrEmpty(cmdline))
                        {
                            var cmdlineShort = cmdline.Length > 100 ? cmdline.Substring(0, 97) + "..." : cmdline;
                            details += $"\nCmd: {cmdlineShort}";
                        }

                        var severity = isZombie ? IssueSeverity.Error :
                                      (cmd is "git" or "npm" or "node" or "cargo" or "rustc" ? IssueSeverity.Error : IssueSeverity.Warning);

                        var message = isZombie
                            ? $"ZOMBIE: {cmd} [{stateDesc}] {elapsedDisplay}"
                            : $"{cmd} on /mnt/c ({elapsedDisplay}, {cpuStr}% CPU)";

                        var suggestion = isZombie
                            ? $"Kill: wsl -e kill -9 {pid}"
                            : "Move to ~/projects/ for 10-100x faster I/O";

                        issues.Add(new PerformanceIssue
                        {
                            Severity = severity,
                            Message = message,
                            Details = details,
                            Suggestion = suggestion,
                            Process = cmd,
                            Path = cwd,
                            Pid = pid,
                            Pids = new List<string> { pid },
                            IoReadBytes = ioRead,
                            IoWriteBytes = ioWrite,
                            IsZombie = isZombie
                        });
                    }
                    catch { /* Skip malformed lines */ }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Process check error: {ex.Message}");
            }

            return issues;
        }

        private List<PerformanceIssue> CheckSlowPatterns()
        {
            var issues = new List<PerformanceIssue>();

            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var commonPaths = new[]
            {
                Path.Combine(userProfile, "source"),
                Path.Combine(userProfile, "projects"),
                Path.Combine(userProfile, "repos"),
                Path.Combine(userProfile, "code"),
                Path.Combine(userProfile, "dev")
            };

            foreach (var basePath in commonPaths.Where(Directory.Exists))
            {
                try
                {
                    var nodeModules = Directory.GetDirectories(basePath, "node_modules", SearchOption.AllDirectories)
                        .Take(3);

                    foreach (var nm in nodeModules)
                    {
                        issues.Add(new PerformanceIssue
                        {
                            Severity = IssueSeverity.Warning,
                            Message = "node_modules found on Windows filesystem",
                            Details = nm,
                            Suggestion = "Run 'npm install' from WSL ~/projects for faster builds",
                            Path = nm
                        });
                    }
                }
                catch { /* Ignore access errors */ }
            }

            return issues;
        }

        private bool IsSlowPath(string path)
        {
            return path.StartsWith("/mnt/") && Regex.IsMatch(path, @"^/mnt/[a-zA-Z]/");
        }
    }

    public class ScanResultsForm : Form
    {
        private readonly ListView _listView;

        public ScanResultsForm(WSLMonitor monitor)
        {
            Text = "WSL Performance Scan Results";
            Size = new Size(650, 420);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Theme.BgDark;
            ForeColor = Theme.FgText;

            _listView = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                BackColor = Theme.BgDark,
                ForeColor = Theme.FgText,
                BorderStyle = BorderStyle.None,
                OwnerDraw = true
            };
            _listView.Columns.Add("Severity", 70);
            _listView.Columns.Add("Issue", 250);
            _listView.Columns.Add("Details", 300);

            _listView.DrawColumnHeader += DrawDarkColumnHeader;
            _listView.DrawItem += (s, e) => { e.DrawDefault = true; };
            _listView.DrawSubItem += (s, e) => { e.DrawDefault = true; };

            var listContextMenu = new ContextMenuStrip { BackColor = Theme.BgPanel, ForeColor = Theme.FgText };
            var copySelectedItem = new ToolStripMenuItem("Copy Selected", null, (s, e) => CopySelected());
            copySelectedItem.ShortcutKeys = Keys.Control | Keys.C;
            var copyAllItem = new ToolStripMenuItem("Copy All", null, (s, e) => CopyAll());
            copyAllItem.ShortcutKeys = Keys.Control | Keys.Shift | Keys.C;
            listContextMenu.Items.Add(copySelectedItem);
            listContextMenu.Items.Add(copyAllItem);
            _listView.ContextMenuStrip = listContextMenu;

            _listView.KeyDown += (s, e) =>
            {
                if (e.Control && e.KeyCode == Keys.C) { CopySelected(); e.Handled = true; }
            };

            var issues = monitor.Scan();
            foreach (var issue in issues)
            {
                var item = new ListViewItem(issue.Severity.ToString());
                item.SubItems.Add(issue.Message);
                item.SubItems.Add(issue.Details ?? "");
                item.ForeColor = Theme.FgText;
                item.BackColor = issue.Severity switch
                {
                    IssueSeverity.Error => Theme.ErrorBg,
                    IssueSeverity.Warning => Theme.WarningBg,
                    _ => Theme.BgDark
                };
                _listView.Items.Add(item);
            }

            if (!issues.Any())
            {
                var item = new ListViewItem("OK");
                item.SubItems.Add("No performance issues detected");
                item.SubItems.Add("All processes running on fast Linux filesystem");
                item.ForeColor = Theme.FgText;
                item.BackColor = Theme.OkBg;
                _listView.Items.Add(item);
            }

            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(5),
                FlowDirection = FlowDirection.RightToLeft, BackColor = Theme.BgPanel
            };
            var copyBtn = new Button { Text = "Copy All", Width = 80 };
            Theme.StyleButton(copyBtn);
            copyBtn.Click += (s, e) => CopyAll();
            buttonPanel.Controls.Add(copyBtn);

            Controls.Add(_listView);
            Controls.Add(buttonPanel);
        }

        private void DrawDarkColumnHeader(object sender, DrawListViewColumnHeaderEventArgs e)
        {
            using var brush = new SolidBrush(Theme.BgPanel);
            e.Graphics.FillRectangle(brush, e.Bounds);
            using var pen = new Pen(Theme.Border);
            e.Graphics.DrawLine(pen, e.Bounds.Right - 1, e.Bounds.Top, e.Bounds.Right - 1, e.Bounds.Bottom);
            e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
            var textBounds = new Rectangle(e.Bounds.X + 4, e.Bounds.Y, e.Bounds.Width - 8, e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, textBounds, Theme.FgText,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        }

        private void CopySelected()
        {
            if (_listView.SelectedItems.Count == 0) return;
            var lines = new List<string>();
            foreach (ListViewItem item in _listView.SelectedItems)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems) cols.Add(sub.Text);
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void CopyAll()
        {
            var lines = new List<string> { "Severity\tIssue\tDetails" };
            foreach (ListViewItem item in _listView.Items)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems) cols.Add(sub.Text);
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }
    }

    public class DashboardForm : Form
    {
        private readonly WSLMonitor _monitor;
        private readonly ListView _issueList;
        private readonly System.Windows.Forms.Timer _refreshTimer;
        private readonly Button _killZombiesBtn;
        private List<PerformanceIssue> _currentGrouped = new();

        public DashboardForm(WSLMonitor monitor)
        {
            _monitor = monitor;
            Text = "WSL Performance Dashboard";
            Size = new Size(950, 550);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Theme.BgDark;
            ForeColor = Theme.FgText;

            // Header
            var headerPanel = new Panel { Dock = DockStyle.Top, Height = 60, BackColor = Theme.BgPanel };
            var titleLabel = new Label
            {
                Text = "WSL2 Performance Dashboard",
                Font = new Font("Segoe UI", 16, FontStyle.Bold),
                ForeColor = Color.White,
                AutoSize = true,
                Location = new Point(15, 15)
            };
            headerPanel.Controls.Add(titleLabel);

            // Issue list with dark theme + owner-drawn headers
            _issueList = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true,
                BackColor = Theme.BgDark,
                ForeColor = Theme.FgText,
                BorderStyle = BorderStyle.None,
                OwnerDraw = true
            };
            _issueList.Columns.Add("", 28);
            _issueList.Columns.Add("Process", 90);
            _issueList.Columns.Add("Issue", 200);
            _issueList.Columns.Add("I/O", 130);
            _issueList.Columns.Add("Path", 220);
            _issueList.Columns.Add("Suggestion", 200);

            _issueList.DrawColumnHeader += DrawDarkColumnHeader;
            _issueList.DrawItem += (s, e) => { e.DrawDefault = true; };
            _issueList.DrawSubItem += (s, e) => { e.DrawDefault = true; };

            // Context menu
            var listContextMenu = new ContextMenuStrip { BackColor = Theme.BgPanel, ForeColor = Theme.FgText };
            var copySelectedItem = new ToolStripMenuItem("Copy Selected", null, (s, e) => CopySelected());
            copySelectedItem.ShortcutKeys = Keys.Control | Keys.C;
            var copyAllItem = new ToolStripMenuItem("Copy All", null, (s, e) => CopyAll());
            copyAllItem.ShortcutKeys = Keys.Control | Keys.Shift | Keys.C;
            listContextMenu.Items.Add(copySelectedItem);
            listContextMenu.Items.Add(copyAllItem);
            _issueList.ContextMenuStrip = listContextMenu;

            _issueList.KeyDown += (s, e) =>
            {
                if (e.Control && e.Shift && e.KeyCode == Keys.C) { CopyAll(); e.Handled = true; }
                else if (e.Control && e.KeyCode == Keys.C) { CopySelected(); e.Handled = true; }
            };

            // Button panel
            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, Height = 50, Padding = new Padding(10),
                FlowDirection = FlowDirection.RightToLeft, BackColor = Theme.BgPanel
            };

            var refreshBtn = new Button { Text = "Refresh", Width = 100 };
            Theme.StyleButton(refreshBtn);
            refreshBtn.Click += (s, e) => RefreshIssues();

            var copyBtn = new Button { Text = "Copy All", Width = 100 };
            Theme.StyleButton(copyBtn);
            copyBtn.Click += (s, e) => CopyAll();

            _killZombiesBtn = new Button { Text = "\u2620 Kill All Zombies", Width = 150, Visible = false };
            Theme.StyleButton(_killZombiesBtn, Theme.Danger);
            _killZombiesBtn.Click += (s, e) => KillAllZombies();

            var migrateBtn = new Button { Text = "Migrate Selected", Width = 120 };
            Theme.StyleButton(migrateBtn);

            buttonPanel.Controls.Add(refreshBtn);
            buttonPanel.Controls.Add(copyBtn);
            buttonPanel.Controls.Add(_killZombiesBtn);
            buttonPanel.Controls.Add(migrateBtn);

            Controls.Add(_issueList);
            Controls.Add(buttonPanel);
            Controls.Add(headerPanel);

            _refreshTimer = new System.Windows.Forms.Timer { Interval = 10000 };
            _refreshTimer.Tick += (s, e) => RefreshIssues();
            _refreshTimer.Start();

            RefreshIssues();
        }

        private void DrawDarkColumnHeader(object sender, DrawListViewColumnHeaderEventArgs e)
        {
            using var brush = new SolidBrush(Theme.BgPanel);
            e.Graphics.FillRectangle(brush, e.Bounds);
            using var pen = new Pen(Theme.Border);
            e.Graphics.DrawLine(pen, e.Bounds.Right - 1, e.Bounds.Top, e.Bounds.Right - 1, e.Bounds.Bottom);
            e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
            var textBounds = new Rectangle(e.Bounds.X + 4, e.Bounds.Y, e.Bounds.Width - 8, e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, textBounds, Theme.FgText,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        }

        private void CopySelected()
        {
            if (_issueList.SelectedItems.Count == 0) return;
            var lines = new List<string>();
            foreach (ListViewItem item in _issueList.SelectedItems)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems) cols.Add(sub.Text);
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void CopyAll()
        {
            var lines = new List<string>();
            var headers = new List<string>();
            foreach (ColumnHeader col in _issueList.Columns) headers.Add(col.Text);
            lines.Add(string.Join("\t", headers));
            foreach (ListViewItem item in _issueList.Items)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems) cols.Add(sub.Text);
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void RefreshIssues()
        {
            _issueList.Items.Clear();
            var issues = _monitor.Scan();

            // Group duplicate rows by (process name, path)
            _currentGrouped = issues
                .GroupBy(i => $"{i.Process}|{i.Path}")
                .Select(g =>
                {
                    var first = g.First();
                    var allPids = g.SelectMany(i => i.Pids.Any() ? i.Pids : new List<string> { i.Pid })
                                   .Where(p => !string.IsNullOrEmpty(p)).ToList();
                    var count = g.Count();
                    return new PerformanceIssue
                    {
                        Severity = g.Max(i => i.Severity),
                        Message = count > 1
                            ? $"{count}x {first.Process} on /mnt/c"
                            : first.Message,
                        Details = first.Details,
                        Suggestion = first.Suggestion,
                        Process = count > 1 ? $"{count}x {first.Process}" : first.Process,
                        Path = first.Path,
                        Pid = first.Pid,
                        Pids = allPids,
                        IoReadBytes = g.Sum(i => i.IoReadBytes),
                        IoWriteBytes = g.Sum(i => i.IoWriteBytes),
                        Count = count,
                        IsZombie = g.Any(i => i.IsZombie)
                    };
                })
                .OrderByDescending(i => i.Severity)
                .ThenByDescending(i => i.IoReadBytes + i.IoWriteBytes)
                .ToList();

            bool hasZombies = false;
            foreach (var issue in _currentGrouped)
            {
                if (issue.IsZombie) hasZombies = true;

                var icon = issue.Severity == IssueSeverity.Error ? "\U0001F534" :
                          issue.Severity == IssueSeverity.Warning ? "\U0001F7E1" : "\U0001F7E2";
                if (issue.IsZombie) icon = "\u2620";

                var item = new ListViewItem(icon);
                item.SubItems.Add(issue.Process ?? "-");
                item.SubItems.Add(issue.Message);

                // I/O throughput column
                var ioText = (issue.IoReadBytes > 0 || issue.IoWriteBytes > 0)
                    ? $"R:{Theme.FormatBytes(issue.IoReadBytes)} W:{Theme.FormatBytes(issue.IoWriteBytes)}"
                    : "-";
                item.SubItems.Add(ioText);

                item.SubItems.Add(issue.Path ?? "-");
                item.SubItems.Add(issue.Suggestion ?? "-");

                item.ForeColor = Theme.FgText;
                item.BackColor = issue.Severity switch
                {
                    IssueSeverity.Error => Theme.ErrorBg,
                    IssueSeverity.Warning => Theme.WarningBg,
                    _ => Theme.BgDark
                };

                _issueList.Items.Add(item);
            }

            // Show/hide Kill Zombies button
            _killZombiesBtn.Visible = hasZombies;

            if (!_currentGrouped.Any())
            {
                var item = new ListViewItem("\U0001F7E2");
                item.SubItems.Add("-");
                item.SubItems.Add("No performance issues detected");
                item.SubItems.Add("-");
                item.SubItems.Add("-");
                item.SubItems.Add("All good!");
                item.ForeColor = Theme.FgText;
                item.BackColor = Theme.OkBg;
                _issueList.Items.Add(item);
            }
        }

        private void KillAllZombies()
        {
            var zombiePids = _currentGrouped
                .Where(i => i.IsZombie)
                .SelectMany(i => i.Pids)
                .Where(p => !string.IsNullOrEmpty(p))
                .Distinct()
                .ToList();

            if (!zombiePids.Any())
            {
                MessageBox.Show("No zombie processes found.", "Kill Zombies",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var result = MessageBox.Show(
                $"Kill {zombiePids.Count} zombie process(es)?\n\nPIDs: {string.Join(", ", zombiePids)}",
                "Kill All Zombies", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);

            if (result != DialogResult.Yes) return;

            try
            {
                var pidList = string.Join(" ", zombiePids);
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl",
                    Arguments = $"-e bash -c \"kill -9 {pidList} 2>/dev/null; echo done\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                process?.WaitForExit(5000);

                RefreshIssues();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to kill processes: {ex.Message}", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            _refreshTimer?.Stop();
            base.OnFormClosing(e);
        }
    }

    public class NewProjectForm : Form
    {
        public string ProjectName { get; private set; }
        public string Template { get; private set; }

        public NewProjectForm()
        {
            Text = "Create New Fast Project";
            Size = new Size(400, 200);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            BackColor = Theme.BgDark;
            ForeColor = Theme.FgText;

            var nameLabel = new Label { Text = "Project Name:", Location = new Point(20, 20), AutoSize = true, ForeColor = Theme.FgText };
            var nameBox = new TextBox { Location = new Point(120, 17), Width = 240, BackColor = Theme.BgControl, ForeColor = Theme.FgText };

            var templateLabel = new Label { Text = "Template:", Location = new Point(20, 55), AutoSize = true, ForeColor = Theme.FgText };
            var templateBox = new ComboBox
            {
                Location = new Point(120, 52), Width = 240,
                DropDownStyle = ComboBoxStyle.DropDownList,
                BackColor = Theme.BgControl, ForeColor = Theme.FgText
            };
            templateBox.Items.AddRange(new[] { "bare", "node", "python", "rust", "git" });
            templateBox.SelectedIndex = 0;

            var createBtn = new Button
            {
                Text = "Create", Location = new Point(200, 110), Width = 80, DialogResult = DialogResult.OK
            };
            Theme.StyleButton(createBtn, Theme.Accent);

            var cancelBtn = new Button
            {
                Text = "Cancel", Location = new Point(290, 110), Width = 80, DialogResult = DialogResult.Cancel
            };
            Theme.StyleButton(cancelBtn);

            createBtn.Click += (s, e) =>
            {
                ProjectName = nameBox.Text.Trim();
                Template = templateBox.SelectedItem?.ToString() ?? "bare";
                if (string.IsNullOrEmpty(ProjectName))
                {
                    MessageBox.Show("Please enter a project name.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    DialogResult = DialogResult.None;
                }
            };

            Controls.AddRange(new Control[] { nameLabel, nameBox, templateLabel, templateBox, createBtn, cancelBtn });
            AcceptButton = createBtn;
            CancelButton = cancelBtn;
        }
    }
}
