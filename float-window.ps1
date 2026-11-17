param(
  [Parameter(Mandatory = $true)][string]$StateFile,
  [int]$ParentPid = 0
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DshActivate {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@

# 让窗口不出现在 Alt+Tab 与任务栏：加上 WS_EX_TOOLWINDOW、去掉 WS_EX_APPWINDOW
function Hide-FromSwitcher {
  try {
    $ex = [DshActivate]::GetWindowLong($form.Handle, -20)
    $ex = ($ex -band (-bnot 0x40000)) -bor 0x80
    [void][DshActivate]::SetWindowLong($form.Handle, -20, $ex)
  } catch {
  }
}

# 窗口不透明度：1.0 = 完全不透明，0.85 = 略透出背景。改这一行即可。
$windowOpacity = 0.85
# 展开宽度 / 贴边收起后的宽度 / 高度
$expandedWidth = 158
$collapsedWidth = 14
$windowHeight = 42
# 空闲多久后自动贴边收起（毫秒）
$idleCollapseDelay = 2500

# 状态文件内容：running | waiting | done | idle；done 可带 ":<epoch-ms>" 标记刚完成
function Read-State {
  try {
    if (-not (Test-Path -LiteralPath $StateFile)) { return @{ state = 'idle'; at = 0 } }
    $text = (Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop).Trim()
    if ($text.Length -eq 0) { return @{ state = 'idle'; at = 0 } }
    $parts = $text.Split(':')
    $state = $parts[0]
    $at = 0
    if ($parts.Length -gt 1) { [void][long]::TryParse($parts[1], [ref]$at) }
    return @{ state = $state; at = $at }
  } catch {
    return @{ state = 'idle'; at = 0 }
  }
}

# 双击或菜单回到 DeepSeek Harness 主窗口
function Activate-App {
  try {
    $app = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne 0 } |
      Select-Object -First 1
    if ($null -eq $app) { return }
    $handle = $app.MainWindowHandle
    # 只在最小化时还原，避免把最大化窗口缩回普通大小
    if ([DshActivate]::IsIconic($handle)) {
      [void][DshActivate]::ShowWindow($handle, 9)
    }
    [void][DshActivate]::SetForegroundWindow($handle)
  } catch {
  }
}

$script:current = 'idle'
$script:flashUntil = 0
$script:dragging = $false
$script:dragX = 0
$script:dragY = 0
$script:ticks = 0
$script:lastVisual = ''
$script:collapsed = $false
$script:hover = $false
$script:idleSince = 0

$red = [System.Drawing.Color]::FromArgb(255, 77, 79)
$amber = [System.Drawing.Color]::FromArgb(255, 176, 32)
$green = [System.Drawing.Color]::FromArgb(34, 197, 94)
$idleColor = [System.Drawing.Color]::FromArgb(122, 128, 144)
$back = [System.Drawing.Color]::FromArgb(31, 36, 48)
$textColor = [System.Drawing.Color]::FromArgb(232, 232, 236, 244)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Width = $expandedWidth
$form.Height = $windowHeight
$form.BackColor = $back
$form.Opacity = $windowOpacity

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Left = $area.Right - $expandedWidth
$form.Top = $area.Bottom - $windowHeight - 24

$picture = New-Object System.Windows.Forms.PictureBox
$picture.Dock = [System.Windows.Forms.DockStyle]::Fill
$picture.BackColor = $back
$picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Normal
$form.Controls.Add($picture)

# 圆角外形随窗口尺寸重建（展开时是胶囊，收起时是贴边的窄条）
function Update-Region {
  $w = $form.Width
  $h = $form.Height
  $r = [Math]::Min(14, [Math]::Min([int]($w / 2), [int]($h / 2)))
  if ($r -lt 2) { $r = 2 }
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0, 0, $r, $r, 180, 90)
  $path.AddArc($w - $r, 0, $r, $r, 270, 90)
  $path.AddArc($w - $r, $h - $r, $r, $r, 0, 90)
  $path.AddArc(0, $h - $r, $r, $r, 90, 90)
  $path.CloseFigure()
  $form.Region = New-Object System.Drawing.Region($path)
  $path.Dispose()
}
Update-Region

function State-Color {
  param([string]$state)
  switch ($state) {
    'running' { return $red }
    'waiting' { return $amber }
    'done' { return $green }
    default { return $idleColor }
  }
}

function New-LightImage {
  $w = $form.ClientSize.Width
  $h = $form.ClientSize.Height
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

  $bg = New-Object System.Drawing.SolidBrush($back)
  $g.FillRectangle($bg, 0, 0, $w, $h)
  $bg.Dispose()

  $state = $script:current
  $justDone = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $script:flashUntil)

  if ($script:collapsed) {
    # 贴边收起：只留一个状态灯
    $size = 8
    $x = [int](($w - $size) / 2)
    $y = [int](($h - $size) / 2)
    $color = State-Color $state
    if ($state -eq 'done' -and $justDone) {
      $glow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, $color))
      $g.FillEllipse($glow, $x - 4, $y - 4, $size + 8, $size + 8)
      $glow.Dispose()
    }
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, $x, $y, $size, $size)
    $brush.Dispose()
  } else {
    $lights = @(
      @{ X = 16; Color = $red; Active = ($state -eq 'running') },
      @{ X = 38; Color = $amber; Active = ($state -eq 'waiting') },
      @{ X = 60; Color = $green; Active = ($state -eq 'done') }
    )
    foreach ($light in $lights) {
      if ($light.Active) {
        if ($state -eq 'done' -and $justDone) {
          $glow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(72, $light.Color))
          $g.FillEllipse($glow, $light.X - 4, 11, 20, 20)
          $glow.Dispose()
        }
        $brush = New-Object System.Drawing.SolidBrush($light.Color)
        $g.FillEllipse($brush, $light.X, 15, 12, 12)
        $brush.Dispose()
      } else {
        $dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(46, $light.Color))
        $g.FillEllipse($dim, $light.X, 15, 12, 12)
        $dim.Dispose()
      }
    }

    $label = switch ($state) {
      'running' { '运行中' }
      'waiting' { '等待你处理' }
      'done' { '已完成' }
      default { '待命' }
    }

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $textBrush = New-Object System.Drawing.SolidBrush($textColor)
    $g.DrawString($label, $font, $textBrush, 82, 13)
    $textBrush.Dispose()
    $font.Dispose()
  }

  $g.Dispose()
  return $bmp
}

function Update-Visual {
  $justDone = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $script:flashUntil)
  $visual = "$($script:current)|$justDone|$($script:collapsed)"
  if ($visual -eq $script:lastVisual) { return }
  $script:lastVisual = $visual
  $old = $picture.Image
  $picture.Image = New-LightImage
  if ($null -ne $old) { $old.Dispose() }
}

# 收起 / 展开：右边缘始终贴着屏幕右边
function Set-Collapsed {
  param([bool]$collapsed)
  if ($script:collapsed -eq $collapsed) { return }
  $script:collapsed = $collapsed
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $width = if ($collapsed) { $collapsedWidth } else { $expandedWidth }
  $top = $form.Top
  if ($top -lt $screen.Top) { $top = $screen.Top }
  if (($top + $windowHeight) -gt $screen.Bottom) { $top = $screen.Bottom - $windowHeight }
  $form.SetBounds($screen.Right - $width, $top, $width, $windowHeight)
  Update-Region
  $script:lastVisual = ''
  Update-Visual
}

# 拖动/双击/右键都挂在铺满窗口的 PictureBox 上：它盖住了 Form，Form 自己收不到鼠标事件
$picture.Add_MouseDown({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:dragging = $true
    $script:dragX = $e.X
    $script:dragY = $e.Y
  }
})
$picture.Add_MouseMove({
  param($sender, $e)
  if ($script:dragging) {
    $form.Left = $form.Left + ($e.X - $script:dragX)
    $form.Top = $form.Top + ($e.Y - $script:dragY)
  }
})
$picture.Add_MouseUp({
  param($sender, $e)
  $script:dragging = $false
})
$picture.Add_MouseEnter({
  $script:hover = $true
  if ($script:collapsed) { Set-Collapsed $false }
})
$picture.Add_MouseLeave({
  $script:hover = $false
})
$picture.Add_DoubleClick({ Activate-App })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('回到 DeepSeek Harness')
$openItem.Add_Click({ Activate-App })
[void]$menu.Items.Add('-')
$closeItem = $menu.Items.Add('关闭红绿灯')
$closeItem.Add_Click({ $form.Close() })
$picture.ContextMenuStrip = $menu
$form.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
  $script:ticks = $script:ticks + 1

  # 宿主进程消失后自行退出，避免留下孤儿窗口
  if ($ParentPid -gt 0 -and ($script:ticks % 12) -eq 0) {
    $alive = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if ($null -eq $alive) { $form.Close(); return }
  }

  $next = Read-State
  if ($next.state -ne $script:current) { $script:current = $next.state }
  if ($next.state -eq 'done' -and $next.at -gt 0 -and ($next.at + 8000) -gt $script:flashUntil) {
    $script:flashUntil = $next.at + 8000
  }

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $busy = ($script:current -eq 'running') -or ($script:current -eq 'waiting')
  if ($busy) {
    $script:idleSince = 0
    Set-Collapsed $false
  } else {
    if ($script:idleSince -eq 0) { $script:idleSince = $now }
    if (-not $script:hover -and -not $script:collapsed -and ($now - $script:idleSince) -gt $idleCollapseDelay) {
      Set-Collapsed $true
    }
  }

  Update-Visual
})
$timer.Start()

$form.Add_Shown({
  Hide-FromSwitcher
  Update-Region
  Update-Visual
})
$form.Add_FormClosed({ $timer.Stop() })

[void][System.Windows.Forms.Application]::Run($form)
