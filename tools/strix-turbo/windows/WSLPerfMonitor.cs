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
    public class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // Single instance check
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

            // Create context menu
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

            // Create tray icon
            _trayIcon = new NotifyIcon
            {
                Icon = CreateIcon(Color.Green),
                Text = "WSL Performance Monitor\nStatus: OK",
                ContextMenuStrip = _contextMenu,
                Visible = true
            };
            _trayIcon.DoubleClick += OnOpenDashboard;

            // Start monitoring timer
            _monitorTimer = new System.Windows.Forms.Timer { Interval = 5000 }; // Check every 5 seconds
            _monitorTimer.Tick += OnMonitorTick;
            _monitorTimer.Start();

            // Initial scan
            Task.Run(() => PerformScan(showNotification: false));
        }

        private Icon CreateIcon(Color color)
        {
            var bitmap = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);

                // Draw "W" for WSL
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

                // Update icon based on status
                if (issues.Any(i => i.Severity == IssueSeverity.Error))
                {
                    UpdateIcon(Color.Red, $"WSL Performance Monitor\n{issues.Count} issues detected");
                }
                else if (issues.Any(i => i.Severity == IssueSeverity.Warning))
                {
                    UpdateIcon(Color.Orange, $"WSL Performance Monitor\n{issues.Count} warnings");
                }
                else
                {
                    UpdateIcon(Color.Green, "WSL Performance Monitor\nStatus: OK");
                }

                // Show notification for new issues
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
                // Dispose old icon to prevent handle leak
                var oldIcon = _trayIcon.Icon;
                _trayIcon.Icon = CreateIcon(color);
                oldIcon.Dispose();
            }
            _trayIcon.Text = tooltip.Length > 63 ? tooltip.Substring(0, 63) : tooltip;
        }

        private void ShowBalloon(PerformanceIssue issue)
        {
            _trayIcon.ShowBalloonTip(
                5000,
                "WSL Performance Warning",
                $"{issue.Message}\n\nClick for suggestions.",
                issue.Severity == IssueSeverity.Error ? ToolTipIcon.Error : ToolTipIcon.Warning
            );
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
                    $"From: {projectPath}\n" +
                    $"To: ~/projects/{projectName}\n\n" +
                    "This will copy the project and create a symlink back to Windows.",
                    "Migrate Project",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question
                );

                if (result == DialogResult.Yes)
                {
                    MigrateProject(projectPath, projectName);
                }
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
                    $"Project migrated successfully!\n\n" +
                    $"Location: {destPath}\n" +
                    $"Windows access: C:\\Users\\{Environment.UserName}\\wsl-projects\\{projectName}",
                    "Migration Complete",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
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
            {
                CreateNewProject(form.ProjectName, form.Template);
            }
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

                // Also create Windows symlink
                command += $" && mkdir -p /mnt/c/Users/{Environment.UserName}/wsl-projects && " +
                          $"ln -sf ~/projects/{name} /mnt/c/Users/{Environment.UserName}/wsl-projects/{name}";

                RunWslCommand(command);

                var result = MessageBox.Show(
                    $"Project created at ~/projects/{name}\n\nOpen in VS Code?",
                    "Project Created",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Information
                );

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
            {
                item.Checked = _warningsEnabled;
            }
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
            // C:\Users\foo -> /mnt/c/Users/foo
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
    }

    public class WSLMonitor
    {
        public List<PerformanceIssue> Scan()
        {
            var issues = new List<PerformanceIssue>();

            try
            {
                // Check for processes with CWD on /mnt/*
                issues.AddRange(CheckWslProcesses());

                // Check for common slow patterns
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
                // Get process info including PID, start time, elapsed time, command, and CWD
                var psi = new ProcessStartInfo
                {
                    FileName = "wsl",
                    Arguments = "-e bash -c \"for pid in $(pgrep -x 'bash|zsh|node|npm|git|python|cargo|rustc|gcc|g++|make' 2>/dev/null | head -20); do cwd=$(readlink /proc/$pid/cwd 2>/dev/null); cmd=$(ps -p $pid -o comm= 2>/dev/null); elapsed=$(ps -p $pid -o etimes= 2>/dev/null | tr -d ' '); cmdline=$(tr '\\\\0' ' ' < /proc/$pid/cmdline 2>/dev/null | head -c 100); echo \\\"$pid|$cmd|$elapsed|$cwd|$cmdline\\\"; done\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                var output = process?.StandardOutput.ReadToEnd() ?? "";
                process?.WaitForExit(5000);

                foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    var parts = line.Split('|', 5);
                    if (parts.Length >= 4)
                    {
                        var pid = parts[0].Trim();
                        var cmd = parts[1].Trim();
                        var elapsedStr = parts[2].Trim();
                        var cwd = parts[3].Trim();
                        var cmdline = parts.Length > 4 ? parts[4].Trim() : "";

                        if (!IsSlowPath(cwd)) continue;

                        // Parse elapsed time (in seconds)
                        int.TryParse(elapsedStr, out int elapsedSeconds);
                        var elapsed = TimeSpan.FromSeconds(elapsedSeconds);

                        // Determine if this is likely a zombie (running > 5 min, or has benchmark/test in cmdline)
                        bool isZombie = elapsedSeconds > 300 || // > 5 minutes
                                       cmdline.Contains("benchmark") ||
                                       cmdline.Contains("test") ||
                                       cmdline.Contains("batch") ||
                                       cmdline.Contains("LD_PRELOAD");

                        // Format elapsed time
                        string elapsedDisplay = elapsed.TotalHours >= 1
                            ? $"{elapsed.Hours}h {elapsed.Minutes}m"
                            : elapsed.TotalMinutes >= 1
                                ? $"{elapsed.Minutes}m {elapsed.Seconds}s"
                                : $"{elapsed.Seconds}s";

                        // Truncate cmdline for display
                        string cmdlineShort = cmdline.Length > 60 ? cmdline.Substring(0, 57) + "..." : cmdline;

                        var severity = isZombie ? IssueSeverity.Error :
                                      (cmd is "git" or "npm" or "node" or "cargo" or "rustc" ? IssueSeverity.Error : IssueSeverity.Warning);

                        var message = isZombie
                            ? $"ZOMBIE: {cmd} stuck for {elapsedDisplay}"
                            : $"{cmd} on slow path ({elapsedDisplay})";

                        var suggestion = isZombie
                            ? $"Kill with: wsl -e kill -9 {pid}"
                            : "Move project to ~/projects/ for 10-100x faster I/O";

                        issues.Add(new PerformanceIssue
                        {
                            Severity = severity,
                            Message = message,
                            Details = string.IsNullOrEmpty(cmdlineShort) ? cwd : $"{cwd}\n{cmdlineShort}",
                            Suggestion = suggestion,
                            Process = isZombie ? $"⚠{cmd}" : cmd,
                            Path = cwd
                        });
                    }
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

            // Check for node_modules on Windows FS being accessed
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
            return path.StartsWith("/mnt/") &&
                   Regex.IsMatch(path, @"^/mnt/[a-zA-Z]/");
        }
    }

    public class ScanResultsForm : Form
    {
        private readonly ListView _listView;

        public ScanResultsForm(WSLMonitor monitor)
        {
            Text = "WSL Performance Scan Results";
            Size = new Size(600, 400);
            StartPosition = FormStartPosition.CenterScreen;

            _listView = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true
            };
            _listView.Columns.Add("Severity", 70);
            _listView.Columns.Add("Issue", 200);
            _listView.Columns.Add("Details", 300);

            // Context menu for copying
            var listContextMenu = new ContextMenuStrip();
            var copySelectedItem = new ToolStripMenuItem("Copy Selected", null, (s, e) => CopySelected());
            copySelectedItem.ShortcutKeys = Keys.Control | Keys.C;
            var copyAllItem = new ToolStripMenuItem("Copy All", null, (s, e) => CopyAll());
            copyAllItem.ShortcutKeys = Keys.Control | Keys.Shift | Keys.C;
            listContextMenu.Items.Add(copySelectedItem);
            listContextMenu.Items.Add(copyAllItem);
            _listView.ContextMenuStrip = listContextMenu;

            // Enable keyboard shortcut
            _listView.KeyDown += (s, e) =>
            {
                if (e.Control && e.KeyCode == Keys.C)
                {
                    CopySelected();
                    e.Handled = true;
                }
            };

            var issues = monitor.Scan();
            foreach (var issue in issues)
            {
                var item = new ListViewItem(issue.Severity.ToString());
                item.SubItems.Add(issue.Message);
                item.SubItems.Add(issue.Details ?? "");
                item.BackColor = issue.Severity switch
                {
                    IssueSeverity.Error => Color.MistyRose,
                    IssueSeverity.Warning => Color.LemonChiffon,
                    _ => Color.White
                };
                _listView.Items.Add(item);
            }

            if (!issues.Any())
            {
                var item = new ListViewItem("OK");
                item.SubItems.Add("No performance issues detected");
                item.SubItems.Add("All processes running on fast Linux filesystem");
                item.BackColor = Color.Honeydew;
                _listView.Items.Add(item);
            }

            // Button panel
            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 40,
                Padding = new Padding(5),
                FlowDirection = FlowDirection.RightToLeft
            };
            var copyBtn = new Button { Text = "Copy All", Width = 80 };
            copyBtn.Click += (s, e) => CopyAll();
            buttonPanel.Controls.Add(copyBtn);

            Controls.Add(_listView);
            Controls.Add(buttonPanel);
        }

        private void CopySelected()
        {
            if (_listView.SelectedItems.Count == 0) return;

            var lines = new List<string>();
            foreach (ListViewItem item in _listView.SelectedItems)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems)
                {
                    cols.Add(sub.Text);
                }
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void CopyAll()
        {
            var lines = new List<string>();

            // Add header
            lines.Add("Severity\tIssue\tDetails");

            // Add rows
            foreach (ListViewItem item in _listView.Items)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems)
                {
                    cols.Add(sub.Text);
                }
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

        public DashboardForm(WSLMonitor monitor)
        {
            _monitor = monitor;
            Text = "WSL Performance Dashboard";
            Size = new Size(800, 500);
            StartPosition = FormStartPosition.CenterScreen;

            // Header panel
            var headerPanel = new Panel { Dock = DockStyle.Top, Height = 60, BackColor = Color.FromArgb(45, 45, 48) };
            var titleLabel = new Label
            {
                Text = "WSL2 Performance Dashboard",
                Font = new Font("Segoe UI", 16, FontStyle.Bold),
                ForeColor = Color.White,
                AutoSize = true,
                Location = new Point(15, 15)
            };
            headerPanel.Controls.Add(titleLabel);

            // Issue list
            _issueList = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true
            };
            _issueList.Columns.Add("", 30);
            _issueList.Columns.Add("Process", 80);
            _issueList.Columns.Add("Issue", 250);
            _issueList.Columns.Add("Path", 300);
            _issueList.Columns.Add("Suggestion", 200);

            // Context menu for copying
            var listContextMenu = new ContextMenuStrip();
            var copySelectedItem = new ToolStripMenuItem("Copy Selected", null, (s, e) => CopySelected());
            copySelectedItem.ShortcutKeys = Keys.Control | Keys.C;
            var copyAllItem = new ToolStripMenuItem("Copy All", null, (s, e) => CopyAll());
            copyAllItem.ShortcutKeys = Keys.Control | Keys.Shift | Keys.C;
            listContextMenu.Items.Add(copySelectedItem);
            listContextMenu.Items.Add(copyAllItem);
            _issueList.ContextMenuStrip = listContextMenu;

            // Enable keyboard shortcut
            _issueList.KeyDown += (s, e) =>
            {
                if (e.Control && e.KeyCode == Keys.C)
                {
                    CopySelected();
                    e.Handled = true;
                }
                else if (e.Control && e.Shift && e.KeyCode == Keys.C)
                {
                    CopyAll();
                    e.Handled = true;
                }
            };

            // Button panel
            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 50,
                Padding = new Padding(10),
                FlowDirection = FlowDirection.RightToLeft
            };

            var refreshBtn = new Button { Text = "Refresh", Width = 100 };
            refreshBtn.Click += (s, e) => RefreshIssues();

            var copyBtn = new Button { Text = "Copy All", Width = 100 };
            copyBtn.Click += (s, e) => CopyAll();

            var migrateBtn = new Button { Text = "Migrate Selected", Width = 120 };

            buttonPanel.Controls.Add(refreshBtn);
            buttonPanel.Controls.Add(copyBtn);
            buttonPanel.Controls.Add(migrateBtn);

            Controls.Add(_issueList);
            Controls.Add(buttonPanel);
            Controls.Add(headerPanel);

            // Auto-refresh
            _refreshTimer = new System.Windows.Forms.Timer { Interval = 10000 };
            _refreshTimer.Tick += (s, e) => RefreshIssues();
            _refreshTimer.Start();

            RefreshIssues();
        }

        private void CopySelected()
        {
            if (_issueList.SelectedItems.Count == 0) return;

            var lines = new List<string>();
            foreach (ListViewItem item in _issueList.SelectedItems)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems)
                {
                    cols.Add(sub.Text);
                }
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void CopyAll()
        {
            var lines = new List<string>();

            // Add header
            var headers = new List<string>();
            foreach (ColumnHeader col in _issueList.Columns)
            {
                headers.Add(col.Text);
            }
            lines.Add(string.Join("\t", headers));

            // Add rows
            foreach (ListViewItem item in _issueList.Items)
            {
                var cols = new List<string>();
                foreach (ListViewItem.ListViewSubItem sub in item.SubItems)
                {
                    cols.Add(sub.Text);
                }
                lines.Add(string.Join("\t", cols));
            }
            Clipboard.SetText(string.Join(Environment.NewLine, lines));
        }

        private void RefreshIssues()
        {
            _issueList.Items.Clear();
            var issues = _monitor.Scan();

            foreach (var issue in issues)
            {
                var item = new ListViewItem(issue.Severity == IssueSeverity.Error ? "🔴" : "🟡");
                item.SubItems.Add(issue.Process ?? "-");
                item.SubItems.Add(issue.Message);
                item.SubItems.Add(issue.Path ?? "-");
                item.SubItems.Add(issue.Suggestion ?? "-");
                _issueList.Items.Add(item);
            }

            if (!issues.Any())
            {
                var item = new ListViewItem("🟢");
                item.SubItems.Add("-");
                item.SubItems.Add("No performance issues detected");
                item.SubItems.Add("-");
                item.SubItems.Add("All good!");
                _issueList.Items.Add(item);
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

            var nameLabel = new Label { Text = "Project Name:", Location = new Point(20, 20), AutoSize = true };
            var nameBox = new TextBox { Location = new Point(120, 17), Width = 240 };

            var templateLabel = new Label { Text = "Template:", Location = new Point(20, 55), AutoSize = true };
            var templateBox = new ComboBox
            {
                Location = new Point(120, 52),
                Width = 240,
                DropDownStyle = ComboBoxStyle.DropDownList
            };
            templateBox.Items.AddRange(new[] { "bare", "node", "python", "rust", "git" });
            templateBox.SelectedIndex = 0;

            var createBtn = new Button
            {
                Text = "Create",
                Location = new Point(200, 110),
                Width = 80,
                DialogResult = DialogResult.OK
            };
            var cancelBtn = new Button
            {
                Text = "Cancel",
                Location = new Point(290, 110),
                Width = 80,
                DialogResult = DialogResult.Cancel
            };

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
