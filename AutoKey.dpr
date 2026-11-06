program AutoKey;

{$APPTYPE GUI}
{$R AutoKey.res}

uses
  Winapi.Windows, Winapi.Messages, Winapi.MMSystem, System.SysUtils, System.Types;

const
  ID_CAPTURE = 101;
  ID_START = 102;
  ID_EXIT = 103;
  ID_INTERVAL = 104;
  MSG_CAPTURED = WM_APP + 1;
  MSG_TOGGLE = WM_APP + 2;
  MSG_SEND_ERROR = WM_APP + 3;
  TIMER_COUNTDOWN = 1;
  TIMER_TEST = 2;
  KEY_INJECTED = $10;
  KEY_EXTENDED = $01;

type
  TKey = record
    VK, Scan: DWORD;
    Extended: Boolean;
  end;
  PKeyboardData = ^TKeyboardData;
  TKeyboardData = record
    VK, Scan, Flags, Time: DWORD;
    Extra: ULONG_PTR;
  end;

var
  MainWnd, KeyLabel, IntervalEdit, StatusLabel, CaptureBtn, StartBtn: HWND;
  TestEdit: HWND;
  Font: HFONT;
  Hook: HHOOK;
  Worker: THandle = 0;
  WakeEvent: THandle = 0;
  WorkerID: DWORD;
  Guard: TRTLCriticalSection;
  Target, PendingKey, OwedKey: TKey;
  HasTarget, Capturing, AwaitRelease, Running, Closing, OwedRelease: Boolean;
  ToggleHeld, ExitHeld, TestMode: Boolean;
  IntervalMS: DWORD = 100;
  Countdown: Integer;
  TestPhase: Integer;
  TestResult: Integer = 1;
  TestCount: Integer;
  TestSendCount, TestPausedSendCount: Integer;
  TestLog: string;

procedure Status(const S: string);
begin
  SetWindowText(StatusLabel, PChar(S));
end;

function KeyName(const K: TKey): string;
var
  B: array[0..127] of Char;
  Flags: Longint;
begin
  if K.VK = VK_SPACE then Exit('空格 Space');
  if (K.VK = VK_RETURN) and K.Extended then Exit('小键盘 Enter');
  Flags := Longint((K.Scan and $FF) shl 16);
  if K.Extended then Flags := Flags or (1 shl 24);
  if GetKeyNameText(Flags, B, Length(B)) > 0 then
    Result := B
  else
    Result := Format('按键 VK 0x%.2x', [K.VK]);
end;

procedure MakeInput(const K: TKey; Up: Boolean; out I: TInput);
begin
  FillChar(I, SizeOf(I), 0);
  I.Itype := INPUT_KEYBOARD;
  if K.Extended then I.ki.dwFlags := KEYEVENTF_EXTENDEDKEY;
  if Up then I.ki.dwFlags := I.ki.dwFlags or KEYEVENTF_KEYUP;
  if (K.Scan <> 0) and (K.VK <> VK_PAUSE) and (K.VK <> VK_SNAPSHOT)
     and not ((K.VK >= $A6) and (K.VK <= $B7)) then
  begin
    I.ki.wScan := K.Scan;
    I.ki.dwFlags := I.ki.dwFlags or KEYEVENTF_SCANCODE;
  end
  else I.ki.wVk := K.VK;
end;

function ReleaseKey(const K: TKey): Boolean;
var
  I: TInput;
  N: Integer;
begin
  MakeInput(K, True, I);
  for N := 1 to 5 do
  begin
    if SendInput(1, I, SizeOf(I)) = 1 then Exit(True);
    Sleep(2);
  end;
  Result := False;
end;

function PressKey(const K: TKey): Boolean;
var
  Inputs: array[0..1] of TInput;
  Sent: UINT;
begin
  MakeInput(K, False, Inputs[0]);
  MakeInput(K, True, Inputs[1]);
  Sent := SendInput(2, Inputs[0], SizeOf(TInput));
  Result := Sent = 2;
  if Sent = 1 then
  begin
    Result := ReleaseKey(K);
    if not Result then
    begin
      OwedKey := K;
      OwedRelease := True;
    end;
  end;
end;

function WorkerProc(Unused: Pointer): DWORD; stdcall;
var
  Delay: DWORD;
  Stop: Boolean;
begin
  Result := 0;
  while True do
  begin
    EnterCriticalSection(Guard);
    try
      Stop := Closing;
      Delay := INFINITE;
      if Running and not Stop then
      begin
        Delay := IntervalMS;
        // Never send into the controls of this tool itself.
        if (TestMode and (GetForegroundWindow = MainWnd)) or
           (not TestMode and (GetForegroundWindow <> MainWnd)) then
          if not PressKey(Target) then
          begin
            Running := False;
            Delay := INFINITE;
            PostMessage(MainWnd, MSG_SEND_ERROR, 0, 0);
          end
          else if TestMode then Inc(TestSendCount);
      end;
    finally
      LeaveCriticalSection(Guard);
    end;
    if Stop then Exit;
    WaitForSingleObject(WakeEvent, Delay);
  end;
end;

procedure Pause;
begin
  KillTimer(MainWnd, TIMER_COUNTDOWN);
  Countdown := 0;
  EnterCriticalSection(Guard);
  Running := False;
  LeaveCriticalSection(Guard);
  SetEvent(WakeEvent);
  EnableWindow(CaptureBtn, True);
  EnableWindow(IntervalEdit, True);
  EnableWindow(StartBtn, HasTarget and not Capturing);
  SetWindowText(StartBtn, '开始（3 秒后）');
  Status('已暂停');
end;

procedure Toggle;
var
  B: array[0..63] of Char;
  Value: Integer;
begin
  if Running or (Countdown > 0) then
  begin
    Pause;
    Exit;
  end;
  if Capturing or not HasTarget then Exit;
  GetWindowText(IntervalEdit, B, Length(B));
  if not TryStrToInt(Trim(string(B)), Value) or (Value < 1) or (Value > 3600000) then
  begin
    MessageBox(MainWnd, '请输入 1 到 3600000 之间的整数毫秒。', '间隔无效', MB_ICONWARNING);
    Exit;
  end;
  EnterCriticalSection(Guard);
  IntervalMS := Value;
  LeaveCriticalSection(Guard);
  EnableWindow(CaptureBtn, False);
  EnableWindow(IntervalEdit, False);
  SetWindowText(StartBtn, '取消 / 暂停');
  Countdown := 3;
  Status('3 秒后开始，请切换到目标窗口');
  SetTimer(MainWnd, TIMER_COUNTDOWN, 1000, nil);
end;

function KeyboardHook(Code: Integer; W: WPARAM; L: LPARAM): LRESULT; stdcall;
var
  D: PKeyboardData;
  Down, Up: Boolean;
begin
  if Code = HC_ACTION then
  begin
    D := PKeyboardData(L);
    Down := (W = WM_KEYDOWN) or (W = WM_SYSKEYDOWN);
    Up := (W = WM_KEYUP) or (W = WM_SYSKEYUP);
    if D.Flags and KEY_INJECTED = 0 then
    begin
      if Capturing then
      begin
        if Down and not AwaitRelease then
        begin
          PendingKey.VK := D.VK;
          PendingKey.Scan := D.Scan;
          PendingKey.Extended := D.Flags and KEY_EXTENDED <> 0;
          AwaitRelease := True;
        end;
        if AwaitRelease and (D.VK = PendingKey.VK) then
        begin
          if Up then
          begin
            Capturing := False;
            AwaitRelease := False;
            PostMessage(MainWnd, MSG_CAPTURED, 0, 0);
          end;
          // Swallow both edges so Space/Enter cannot click the capture button.
          Exit(1);
        end;
      end
      else
      begin
        if Up then
        begin
          if D.VK = VK_F8 then ToggleHeld := False;
          if D.VK = VK_F9 then ExitHeld := False;
        end;
        if Down and (GetAsyncKeyState(VK_CONTROL) < 0) and
           (GetAsyncKeyState(VK_MENU) < 0) then
        begin
          if D.VK = VK_F8 then
          begin
            if not ToggleHeld then PostMessage(MainWnd, MSG_TOGGLE, 0, 0);
            ToggleHeld := True;
            Exit(1);
          end;
          if D.VK = VK_F9 then
          begin
            if not ExitHeld then PostMessage(MainWnd, WM_CLOSE, 0, 0);
            ExitHeld := True;
            Exit(1);
          end;
        end;
      end;
    end;
  end;
  Result := CallNextHookEx(Hook, Code, W, L);
end;

function Control(const Kind, Caption: string; Style: DWORD;
  X, Y, Width, Height, ID: Integer): HWND;
begin
  Result := CreateWindowEx(0, PChar(Kind), PChar(Caption), WS_CHILD or WS_VISIBLE or Style,
    X, Y, Width, Height, MainWnd, HMENU(ID), HInstance, nil);
  SendMessage(Result, WM_SETFONT, WPARAM(Font), 1);
end;

procedure CreateControls;
begin
  Font := CreateFont(-18, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
    DEFAULT_PITCH, 'Microsoft YaHei UI');
  Control('STATIC', '自动按键器', 0, 24, 20, 500, 30, 0);
  Control('STATIC', '目标按键', 0, 24, 75, 95, 26, 0);
  KeyLabel := Control('STATIC', '尚未录入', 0, 126, 75, 260, 26, 0);
  CaptureBtn := Control('BUTTON', '录入按键', WS_TABSTOP, 393, 66, 150, 38, ID_CAPTURE);
  Control('STATIC', '间隔毫秒', 0, 24, 130, 95, 26, 0);
  IntervalEdit := Control('EDIT', '100', WS_BORDER or WS_TABSTOP or ES_NUMBER,
    126, 123, 140, 34, ID_INTERVAL);
  Control('STATIC', '1000 毫秒 = 1 秒', 0, 286, 130, 245, 26, 0);
  StartBtn := Control('BUTTON', '开始（3 秒后）', WS_TABSTOP, 24, 188, 340, 43, ID_START);
  Control('BUTTON', '退出', WS_TABSTOP, 393, 188, 150, 43, ID_EXIT);
  EnableWindow(StartBtn, False);
  StatusLabel := Control('STATIC', '请先点击“录入按键”，再按下并松开目标键。', 0,
    24, 252, 522, 48, 0);
  Control('STATIC', 'Ctrl+Alt+F8：开始 / 暂停    Ctrl+Alt+F9：退出', 0,
    24, 310, 522, 26, 0);
  Control('STATIC', '发送到前台窗口；本窗口在前台时暂不发送。', 0,
    24, 345, 522, 26, 0);
end;

procedure BeginCapture;
begin
  if Running or (Countdown > 0) then Exit;
  if Capturing then
  begin
    // Once a down has been swallowed, allow its release to finish capture.
    if AwaitRelease then Exit;
    Capturing := False;
    SetWindowText(CaptureBtn, '录入按键');
    EnableWindow(StartBtn, HasTarget);
    Status('录入已取消');
    Exit;
  end;
  Capturing := True;
  AwaitRelease := False;
  SetFocus(MainWnd);
  SetWindowText(CaptureBtn, '取消录入');
  EnableWindow(StartBtn, False);
  Status('请单独按下并松开目标键（包括空格、Enter、F1 等）。');
end;

procedure SelfTestStep;
var
  D: TKeyboardData;
  B: array[0..255] of Char;
  F: TextFile;
begin
  try
    case TestPhase of
      0:
        begin
          BeginCapture;
          FillChar(D, SizeOf(D), 0);
          D.VK := VK_SPACE;
          D.Scan := $39;
          if KeyboardHook(HC_ACTION, WM_KEYDOWN, LPARAM(@D)) <> 1 then
            raise Exception.Create('Capture did not swallow space down');
          if KeyboardHook(HC_ACTION, WM_KEYUP, LPARAM(@D)) <> 1 then
            raise Exception.Create('Capture did not swallow space up');
        end;
      1:
        begin
          if not HasTarget or (Target.VK <> VK_SPACE) or not IsWindowEnabled(StartBtn) then
            raise Exception.Create('Space capture/start state failed');
          TestEdit := Control('EDIT', '', WS_BORDER, 24, 252, 510, 40, 200);
          SetWindowText(IntervalEdit, '40');
          Toggle;
          SetForegroundWindow(MainWnd);
          SetFocus(TestEdit);
        end;
      2:
        begin
          if Countdown > 0 then Exit;
          if not Running then raise Exception.Create('Countdown did not start worker');
        end;
      3:
        begin
          Pause;
          EnterCriticalSection(Guard);
          TestPausedSendCount := TestSendCount;
          LeaveCriticalSection(Guard);
          // Allow input accepted before Pause to drain through the UI queue.
        end;
      4:
        begin
          TestCount := GetWindowTextLength(TestEdit);
          if TestCount < 3 then raise Exception.Create('Live SendInput produced too few spaces');
        end;
      5:
        begin
          // Already accepted Windows input may arrive late; verify the sender
          // is stopped instead of mistaking delayed WM_CHAR for a new send.
          EnterCriticalSection(Guard);
          try
            if TestSendCount <> TestPausedSendCount then
              raise Exception.Create('Worker continued after pause');
          finally
            LeaveCriticalSection(Guard);
          end;
          GetWindowText(TestEdit, B, Length(B));
          if Trim(string(B)) <> '' then raise Exception.Create('Expected spaces only');
          TestResult := 0;
          TestLog := Format('PASS: space capture, enabled start, 3-second countdown, live SendInput (%d spaces), pause, shutdown.', [TestCount]);
          PostMessage(MainWnd, WM_CLOSE, 0, 0);
        end;
    end;
    Inc(TestPhase);
  except
    on E: Exception do
    begin
      TestLog := 'FAIL: ' + E.Message;
      PostMessage(MainWnd, WM_CLOSE, 0, 0);
    end;
  end;
  if TestLog <> '' then
  begin
    AssignFile(F, ParamStr(2));
    Rewrite(F);
    Writeln(F, TestLog);
    CloseFile(F);
  end;
end;

function WindowProc(Wnd: HWND; Msg: UINT; W: WPARAM; L: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_COMMAND:
      if HiWord(W) = BN_CLICKED then
        case LoWord(W) of
          ID_CAPTURE: BeginCapture;
          ID_START: Toggle;
          ID_EXIT: PostMessage(Wnd, WM_CLOSE, 0, 0);
        end;
    MSG_CAPTURED:
      begin
        EnterCriticalSection(Guard);
        Target := PendingKey;
        LeaveCriticalSection(Guard);
        HasTarget := True;
        SetWindowText(KeyLabel, PChar(KeyName(Target)));
        SetWindowText(CaptureBtn, '重新录入');
        EnableWindow(StartBtn, True);
        Status('录入完成。设置间隔后点击开始。');
      end;
    MSG_TOGGLE: Toggle;
    MSG_SEND_ERROR:
      begin
        Pause;
        Status('发送失败；目标若以管理员身份运行，本程序也需同样权限。');
        if OwedRelease then
        begin
          OwedRelease := not ReleaseKey(OwedKey);
          if OwedRelease then
            MessageBox(Wnd, '请手动按下并松开目标键一次。', '按键抬起失败', MB_ICONWARNING);
        end;
      end;
    WM_TIMER:
      if W = TIMER_TEST then SelfTestStep
      else if W = TIMER_COUNTDOWN then
      begin
        Dec(Countdown);
        if Countdown > 0 then Status(Format('%d 秒后开始，请切换到目标窗口', [Countdown]))
        else
        begin
          KillTimer(Wnd, TIMER_COUNTDOWN);
          EnterCriticalSection(Guard);
          Running := True;
          LeaveCriticalSection(Guard);
          SetEvent(WakeEvent);
          SetWindowText(StartBtn, '暂停');
          Status('运行中。切换到目标窗口后发送，Ctrl+Alt+F8 暂停。');
        end;
      end;
    WM_CLOSE: DestroyWindow(Wnd);
    WM_DESTROY:
      begin
        EnterCriticalSection(Guard);
        Closing := True;
        Running := False;
        LeaveCriticalSection(Guard);
        SetEvent(WakeEvent);
        PostQuitMessage(0);
      end;
    else Result := DefWindowProc(Wnd, Msg, W, L);
  end;
end;

var
  WC: TWndClass;
  Msg: TMsg;
  R: TRect;
begin
  TestMode := SameText(ParamStr(1), '--self-test');
  InitializeCriticalSection(Guard);
  WakeEvent := CreateEvent(nil, False, False, nil);
  try
    if WakeEvent = 0 then RaiseLastOSError;
    FillChar(WC, SizeOf(WC), 0);
    WC.lpfnWndProc := @WindowProc;
    WC.hInstance := HInstance;
    WC.hCursor := LoadCursor(0, IDC_ARROW);
    WC.hIcon := LoadIcon(HInstance, 'MAINICON');
    WC.hbrBackground := COLOR_BTNFACE + 1;
    WC.lpszClassName := 'DelphiAutoKeyWindow';
    if RegisterClass(WC) = 0 then RaiseLastOSError;
    R := Rect(0, 0, 568, 396);
    AdjustWindowRect(R, WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX, False);
    MainWnd := CreateWindowEx(0, WC.lpszClassName, '自动按键器',
      WS_OVERLAPPED or WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX,
      Integer(CW_USEDEFAULT), Integer(CW_USEDEFAULT), R.Right-R.Left, R.Bottom-R.Top, 0, 0, HInstance, nil);
    if MainWnd = 0 then RaiseLastOSError;
    SendMessage(MainWnd, WM_SETICON, ICON_SMALL,
      LPARAM(LoadImage(HInstance, 'MAINICON', IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED)));
    CreateControls;
    Hook := SetWindowsHookEx(WH_KEYBOARD_LL, @KeyboardHook, HInstance, 0);
    if Hook = 0 then RaiseLastOSError;
    timeBeginPeriod(1);
    Worker := CreateThread(nil, 0, @WorkerProc, nil, 0, WorkerID);
    if Worker = 0 then RaiseLastOSError;
    ShowWindow(MainWnd, SW_SHOWNORMAL);
    UpdateWindow(MainWnd);
    if TestMode then SetTimer(MainWnd, TIMER_TEST, 350, nil);
    while Integer(GetMessage(Msg, 0, 0, 0)) > 0 do
      if not IsDialogMessage(MainWnd, Msg) then
      begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
  except
    on E: Exception do MessageBox(0, PChar(E.Message), '启动失败', MB_ICONERROR);
  end;
  EnterCriticalSection(Guard);
  Closing := True;
  Running := False;
  LeaveCriticalSection(Guard);
  if WakeEvent <> 0 then SetEvent(WakeEvent);
  if Worker <> 0 then
  begin
    WaitForSingleObject(Worker, INFINITE);
    CloseHandle(Worker);
  end;
  if Hook <> 0 then UnhookWindowsHookEx(Hook);
  if OwedRelease then ReleaseKey(OwedKey);
  timeEndPeriod(1);
  if WakeEvent <> 0 then CloseHandle(WakeEvent);
  if Font <> 0 then DeleteObject(Font);
  DeleteCriticalSection(Guard);
  if TestMode then Halt(TestResult);
end.
