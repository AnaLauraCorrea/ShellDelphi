unit ShellDelphi;

// ShellDelphi - componente VCL com PowerShell embutido em multiplas abas.
// Cada aba = 1 ConPTY + 1 emulador de terminal, independentes entre si.
// Visual proprio (dark), sem depender de VCL Styles nem do tema do Windows.
// Delphi 10.2.3 Tokyo / Win32 / ASCII puro.

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls,
  Vcl.Graphics, Vcl.Forms, Vcl.Dialogs, Vcl.FileCtrl,
  ShellDelphi.ConPTY, ShellDelphi.Terminal;

const
  // paleta (BGR, formato TColor)
  clSdBack     = $001E1E1E;   // fundo do terminal
  clSdChrome   = $00252526;   // barra de abas
  clSdToolbar  = $00302D2D;   // barra de acoes
  clSdTabIdle  = $002D2D2D;
  clSdTabHover = $00423E3E;
  clSdBtn      = $003C3C3C;
  clSdBtnHover = $00505050;
  clSdAccent   = $009C630E;   // #0E639C
  clSdText     = $00E5E5E5;
  clSdTextDim  = $00969696;
  clSdBorder   = $00463F3F;

  // Pedido de remocao adiado: PtyExit roda DENTRO do TConPty, entao destruir a
  // sessao ali liberaria o objeto que ainda esta na pilha (use-after-free).
  CM_SHELL_REMOVE = WM_USER + 771;

type
  TShellDelphi = class;

  { Botao flat desenhado a mao - evita brigar com o tema do Windows }
  TShellToolButton = class(TGraphicControl)
  private
    FCaption: string;
    FHover: Boolean;
    FAccent: Boolean;
    procedure SetCaption(const V: string);
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Caption: string read FCaption write SetCaption;
    property Accent: Boolean read FAccent write FAccent;
    property Font;
    property OnClick;
  end;

  { Uma aba: terminal + processo }
  TShellSession = class
  private
    FOwner: TShellDelphi;
    FTerm: TShellTerminal;
    FPty: TConPty;
    FCaption: string;
    FTitle: string;
    FClosed: Boolean;
    FDirCurto: string;   // nome da pasta, para identificar a aba
    procedure TermSend(Sender: TObject; const Data: TBytes);
    procedure TermResize(Sender: TObject; ACols, ARows: Integer);
    procedure TermTitle(Sender: TObject);
    procedure PtyData(Sender: TObject; const Data: TBytes);
    procedure PtyExit(Sender: TObject; ExitCode: Cardinal);
    function GetRunning: Boolean;
    function GetTabText: string;
  public
    constructor Create(AOwner: TShellDelphi; const ACaption: string);
    destructor Destroy; override;
    function Start(const ACommandLine, AWorkDir: string): Boolean;
    procedure SendCommand(const ACommand: string);
    procedure Focus;
    property Terminal: TShellTerminal read FTerm;
    property Pty: TConPty read FPty;
    property Caption: string read FCaption;
    property TabText: string read GetTabText;
    property Running: Boolean read GetRunning;
  end;

  { Barra de abas propria: dark, com "x" por aba e "+" no fim }
  TShellTabStrip = class(TCustomControl)
  private
    FShell: TShellDelphi;
    FHotTab: Integer;
    FHotClose: Boolean;
    FHotPlus: Boolean;
    function TabWidth: Integer;
    function TabRect(AIndex: Integer): TRect;
    function CloseRect(AIndex: Integer): TRect;
    function PlusRect: TRect;
    procedure HitTest(X, Y: Integer; out ATab: Integer; out AClose, APlus: Boolean);
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  // Perguntado a cada aba nova. Deixa o hospedeiro (a IDE) informar a pasta
  // do projeto ATUAL, em vez de congelar a do momento em que a janela abriu.
  TShellDirEvent = procedure(Sender: TObject; var ADir: string) of object;

  TShellTabEvent = procedure(Sender: TObject; Session: TShellSession) of object;
  TShellExitEvent = procedure(Sender: TObject; Session: TShellSession; ExitCode: Cardinal) of object;

  TShellDelphi = class(TCustomPanel)
  private
    FToolbar: TPanel;
    FToolbarLine: TPanel;
    FTabs: TShellTabStrip;
    FClient: TPanel;
    FBtnNova: TShellToolButton;
    FBtnClaude: TShellToolButton;
    FBtnFechar: TShellToolButton;
    FBtnPasta: TShellToolButton;
    FSessions: TObjectList<TShellSession>;
    FActiveIndex: Integer;
    FShellPath: string;
    FWorkDir: string;
    FStartupCommand: string;
    FClaudePath: string;
    FTermFont: TFont;
    FShowToolbar: Boolean;
    FKeepAliveOnExit: Boolean;
    FWorkDirFixo: Boolean;   // usuario escolheu a pasta na mao
    FOnGetWorkDir: TShellDirEvent;
    FOnTabOpened: TShellTabEvent;
    FOnTabClosed: TShellTabEvent;
    FOnShellExit: TShellExitEvent;

    procedure BtnNovaClick(Sender: TObject);
    procedure BtnClaudeClick(Sender: TObject);
    procedure BtnFecharClick(Sender: TObject);
    procedure BtnPastaClick(Sender: TObject);
    function GetActiveSession: TShellSession;
    function GetSessionCount: Integer;
    function GetSession(Index: Integer): TShellSession;
    procedure SetTermFont(const V: TFont);
    procedure SetShowToolbar(const V: Boolean);
    procedure RemoveSession(ASession: TShellSession);
    procedure RemoveSessionEx(ASession: TShellSession; ANotify: Boolean);
    procedure CMShellRemove(var Msg: TMessage); message CM_SHELL_REMOVE;
    function ResolveClaudeExe: string;
    function DirParaNovaAba: string;
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Abre nova aba. ACommandLine vazio usa ShellPath.
    function NewTab(const ACaption: string = ''; const ACommandLine: string = '';
      const AWorkDir: string = ''): TShellSession;
    // Atalho: abre aba ja rodando Claude Code no diretorio informado
    function NewClaudeTab(const AWorkDir: string = ''): TShellSession;
    procedure CloseTab(AIndex: Integer);
    procedure CloseActiveTab;
    procedure CloseAll;
    procedure ActivateTab(AIndex: Integer);
    // Envia texto + Enter para a aba ativa
    procedure SendToActive(const ACommand: string);

    property ActiveSession: TShellSession read GetActiveSession;
    property ActiveIndex: Integer read FActiveIndex;
    property SessionCount: Integer read GetSessionCount;
    property Sessions[Index: Integer]: TShellSession read GetSession;
  published
    property Align;
    property Anchors;
    property BevelOuter default bvNone;
    property Visible;
    property ShellPath: string read FShellPath write FShellPath;
    property WorkDir: string read FWorkDir write FWorkDir;
    property StartupCommand: string read FStartupCommand write FStartupCommand;
    // Caminho explicito do claude.exe; vazio = detecta automaticamente
    property ClaudePath: string read FClaudePath write FClaudePath;
    property TerminalFont: TFont read FTermFont write SetTermFont;
    property ShowToolbar: Boolean read FShowToolbar write SetShowToolbar default True;
    property KeepAliveOnExit: Boolean read FKeepAliveOnExit write FKeepAliveOnExit default False;
    property OnTabOpened: TShellTabEvent read FOnTabOpened write FOnTabOpened;
    property OnTabClosed: TShellTabEvent read FOnTabClosed write FOnTabClosed;
    property OnShellExit: TShellExitEvent read FOnShellExit write FOnShellExit;
    property OnGetWorkDir: TShellDirEvent read FOnGetWorkDir write FOnGetWorkDir;
  end;

// Abre o ShellDelphiHost.exe em processo separado. Use quando a thread
// principal do app/IDE puder travar (compilacao, carga longa) e o terminal
// ainda precisar responder.
function LaunchShellDelphiHost(const AWorkDir: string; AClaude: Boolean = False;
  const AHostExe: string = ''): Boolean;

procedure Register;

implementation

const
  cTabH     = 32;
  cToolbarH = 40;
  cTabMaxW  = 210;
  cTabMinW  = 90;
  cPlusW    = 30;

// Corta o texto com reticencias quando nao cabe na largura informada
function Ellipsize(ACanvas: TCanvas; const S: string; AMaxW: Integer): string;
var
  T: string;
begin
  if AMaxW <= 0 then Exit('');
  if ACanvas.TextWidth(S) <= AMaxW then Exit(S);
  T := S;
  while (T <> '') and (ACanvas.TextWidth(T + '...') > AMaxW) do
    SetLength(T, Length(T) - 1);
  Result := T + '...';
end;

{ TShellToolButton }

constructor TShellToolButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := 26;
  Width := 100;
end;

procedure TShellToolButton.SetCaption(const V: string);
begin
  FCaption := V;
  Invalidate;
end;

procedure TShellToolButton.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FHover := True;
  Invalidate;
end;

procedure TShellToolButton.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHover := False;
  Invalidate;
end;

procedure TShellToolButton.Paint;
var
  BG: TColor;
  R: TRect;
begin
  if FAccent then
  begin
    if FHover then BG := $00B87A22 else BG := clSdAccent;
  end
  else
  begin
    if FHover then BG := clSdBtnHover else BG := clSdBtn;
  end;

  Canvas.Brush.Color := BG;
  Canvas.Pen.Color := BG;
  Canvas.RoundRect(0, 0, Width, Height, 6, 6);

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Assign(Font);
  Canvas.Font.Color := clSdText;
  R := ClientRect;
  Canvas.TextRect(R, FCaption, [tfCenter, tfVerticalCenter, tfSingleLine]);
end;

{ TShellTabStrip }

constructor TShellTabStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  Height := cTabH;
  FHotTab := -1;
end;

procedure TShellTabStrip.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1;
end;

function TShellTabStrip.TabWidth: Integer;
var
  N, Avail: Integer;
begin
  N := FShell.SessionCount;
  if N = 0 then Exit(cTabMinW);
  Avail := Width - cPlusW - 4;
  if Avail < cTabMinW then Avail := cTabMinW;
  Result := Avail div N;
  if Result > cTabMaxW then Result := cTabMaxW;
  if Result < cTabMinW then Result := cTabMinW;
end;

function TShellTabStrip.TabRect(AIndex: Integer): TRect;
var
  W: Integer;
begin
  W := TabWidth;
  Result := Rect(AIndex * W, 0, AIndex * W + W - 1, Height);
end;

function TShellTabStrip.CloseRect(AIndex: Integer): TRect;
var
  R: TRect;
begin
  R := TabRect(AIndex);
  Result := Rect(R.Right - 22, (Height - 16) div 2, R.Right - 6, (Height - 16) div 2 + 16);
end;

function TShellTabStrip.PlusRect: TRect;
var
  X: Integer;
begin
  X := FShell.SessionCount * TabWidth;
  Result := Rect(X + 2, 4, X + 2 + cPlusW - 8, Height - 6);
end;

procedure TShellTabStrip.Paint;
var
  I, CX: Integer;
  R, RC: TRect;
  S: string;
  Active: Boolean;
begin
  Canvas.Brush.Color := clSdChrome;
  Canvas.FillRect(ClientRect);
  Canvas.Font.Assign(Font);

  for I := 0 to FShell.SessionCount - 1 do
  begin
    R := TabRect(I);
    if R.Left >= Width then Break;
    Active := I = FShell.ActiveIndex;

    if Active then
      Canvas.Brush.Color := clSdBack
    else if I = FHotTab then
      Canvas.Brush.Color := clSdTabHover
    else
      Canvas.Brush.Color := clSdTabIdle;
    Canvas.Brush.Style := bsSolid;
    Canvas.FillRect(R);

    // faixa de destaque no topo da aba ativa
    if Active then
    begin
      Canvas.Brush.Color := clSdAccent;
      Canvas.FillRect(Rect(R.Left, 0, R.Right, 2));
    end;

    Canvas.Brush.Style := bsClear;
    if Active then
      Canvas.Font.Color := clSdText
    else
      Canvas.Font.Color := clSdTextDim;

    S := Ellipsize(Canvas, FShell.Sessions[I].TabText, R.Right - R.Left - 36);
    RC := Rect(R.Left + 10, R.Top, R.Right - 24, R.Bottom);
    Canvas.TextRect(RC, S, [tfLeft, tfVerticalCenter, tfSingleLine]);

    // "x" de fechar
    RC := CloseRect(I);
    if (I = FHotTab) and FHotClose then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := $003B3BC5;
      Canvas.Pen.Color := $003B3BC5;
      Canvas.RoundRect(RC.Left, RC.Top, RC.Right, RC.Bottom, 4, 4);
    end;
    Canvas.Pen.Color := clSdText;
    Canvas.MoveTo(RC.Left + 5, RC.Top + 5);
    Canvas.LineTo(RC.Right - 5, RC.Bottom - 5);
    Canvas.MoveTo(RC.Right - 6, RC.Top + 5);
    Canvas.LineTo(RC.Left + 4, RC.Bottom - 5);
    Canvas.Brush.Style := bsSolid;
  end;

  // botao "+"
  R := PlusRect;
  if FHotPlus then
  begin
    Canvas.Brush.Color := clSdTabHover;
    Canvas.Pen.Color := clSdTabHover;
    Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 4, 4);
  end;
  Canvas.Pen.Color := clSdText;
  CX := (R.Left + R.Right) div 2;
  Canvas.MoveTo(CX, R.Top + 6);
  Canvas.LineTo(CX, R.Bottom - 6);
  Canvas.MoveTo(R.Left + 6, (R.Top + R.Bottom) div 2);
  Canvas.LineTo(R.Right - 6, (R.Top + R.Bottom) div 2);

  // linha inferior separando da area do terminal
  Canvas.Brush.Color := clSdBorder;
  Canvas.FillRect(Rect(0, Height - 1, Width, Height));
end;

procedure TShellTabStrip.HitTest(X, Y: Integer; out ATab: Integer;
  out AClose, APlus: Boolean);
var
  I: Integer;
  R: TRect;
begin
  ATab := -1;
  AClose := False;
  APlus := PtInRect(PlusRect, Point(X, Y));
  if APlus then Exit;

  for I := 0 to FShell.SessionCount - 1 do
  begin
    R := TabRect(I);
    if (X >= R.Left) and (X < R.Right) then
    begin
      ATab := I;
      AClose := PtInRect(CloseRect(I), Point(X, Y));
      Exit;
    end;
  end;
end;

procedure TShellTabStrip.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  T: Integer;
  C, P: Boolean;
begin
  inherited;
  HitTest(X, Y, T, C, P);
  if (T <> FHotTab) or (C <> FHotClose) or (P <> FHotPlus) then
  begin
    FHotTab := T;
    FHotClose := C;
    FHotPlus := P;
    Invalidate;
  end;
end;

procedure TShellTabStrip.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHotTab := -1;
  FHotClose := False;
  FHotPlus := False;
  Invalidate;
end;

procedure TShellTabStrip.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  T: Integer;
  C, P: Boolean;
begin
  inherited;
  if Button <> mbLeft then Exit;
  HitTest(X, Y, T, C, P);

  if P then
  begin
    FShell.NewTab;
    Exit;
  end;
  if T < 0 then Exit;
  if C then
    FShell.CloseTab(T)
  else
    FShell.ActivateTab(T);
end;

{ TShellSession }

constructor TShellSession.Create(AOwner: TShellDelphi; const ACaption: string);
begin
  inherited Create;
  FOwner := AOwner;
  FCaption := ACaption;

  FTerm := TShellTerminal.Create(AOwner);
  FTerm.Parent := AOwner.FClient;
  FTerm.Align := alClient;
  FTerm.Font.Assign(AOwner.FTermFont);
  FTerm.Visible := False;
  FTerm.OnSend := TermSend;
  FTerm.OnResizeTerm := TermResize;
  FTerm.OnTitle := TermTitle;

  FPty := TConPty.Create;
  FPty.OnData := PtyData;
  FPty.OnExit := PtyExit;
end;

destructor TShellSession.Destroy;
begin
  if Assigned(FTerm) then
  begin
    FTerm.OnSend := nil;
    FTerm.OnResizeTerm := nil;
    FTerm.OnTitle := nil;
  end;
  if Assigned(FPty) then
  begin
    FPty.OnData := nil;
    FPty.OnExit := nil;
    FPty.Free;
    FPty := nil;
  end;
  FreeAndNil(FTerm);
  inherited;
end;

function TShellSession.GetRunning: Boolean;
begin
  Result := Assigned(FPty) and FPty.Running and (not FClosed);
end;

function TShellSession.GetTabText: string;
begin
  if FClosed then
    Exit(FCaption + ' (encerrado)');

  // O titulo do shell costuma ser so "powershell.exe", igual em toda aba.
  // A pasta identifica melhor de que projeto a aba e.
  if FDirCurto <> '' then
    Result := FDirCurto
  else if FTitle <> '' then
    Result := FTitle
  else
    Result := FCaption;
end;

function TShellSession.Start(const ACommandLine, AWorkDir: string): Boolean;
begin
  // garante metricas/tamanho do terminal antes de criar o pseudoconsole
  FTerm.Visible := True;
  FTerm.HandleNeeded;
  Application.ProcessMessages;

  FDirCurto := ExtractFileName(ExcludeTrailingPathDelimiter(AWorkDir));

  Result := FPty.Start(ACommandLine, AWorkDir, FTerm.Cols, FTerm.Rows);
  FClosed := not Result;
  if Result and FTerm.CanFocus then
    FTerm.SetFocus;
end;

procedure TShellSession.SendCommand(const ACommand: string);
begin
  if Assigned(FPty) and FPty.Running then
    FPty.Write(ACommand + #13);
end;

procedure TShellSession.Focus;
begin
  if Assigned(FTerm) and FTerm.Visible and FTerm.CanFocus then
    FTerm.SetFocus;
end;

procedure TShellSession.TermSend(Sender: TObject; const Data: TBytes);
begin
  if Assigned(FPty) then
    FPty.Write(Data);
end;

procedure TShellSession.TermResize(Sender: TObject; ACols, ARows: Integer);
begin
  if Assigned(FPty) then
    FPty.Resize(ACols, ARows);
end;

procedure TShellSession.TermTitle(Sender: TObject);
var
  T: string;
begin
  // titulos de shell vem enormes ("Administrador: C:\...\powershell.exe");
  // na aba so interessa a parte final
  T := FTerm.Title;
  if Pos('\', T) > 0 then
    T := ExtractFileName(T);
  FTitle := Trim(T);
  if Assigned(FOwner) and Assigned(FOwner.FTabs) then
    FOwner.FTabs.Invalidate;
end;

procedure TShellSession.PtyData(Sender: TObject; const Data: TBytes);
begin
  if Assigned(FTerm) then
  begin
    // SCROLL-FIX - Resumo breve: nao voltar ao rodape a cada bloco recebido. O
    // ScrollToBottom aqui zerava a rolagem do usuario a cada chunk do ConPTY -
    // com um programa que escreve sem parar (spinner do Claude Code, build,
    // ping) a roda parecia morta. Quem nao rolou ja fica preso no rodape pelo
    // FAtBottom do ScrollRegionUp, e digitar volta ao rodape pelo KeyDown.
    FTerm.Feed(Data);
  end;
end;

procedure TShellSession.PtyExit(Sender: TObject; ExitCode: Cardinal);
begin
  FClosed := True;
  if Assigned(FOwner) and Assigned(FOwner.FTabs) then
    FOwner.FTabs.Invalidate;
  if Assigned(FOwner) and Assigned(FOwner.FOnShellExit) then
    FOwner.FOnShellExit(FOwner, Self, ExitCode);
  // NAO destruir aqui: este metodo foi chamado pelo proprio TConPty desta
  // sessao. A remocao vai por mensagem, ja fora da pilha do evento.
  if Assigned(FOwner) and (not FOwner.FKeepAliveOnExit) and FOwner.HandleAllocated then
    PostMessage(FOwner.Handle, CM_SHELL_REMOVE, 0, LPARAM(Self));
end;

{ TShellDelphi }

constructor TShellDelphi.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := clSdBack;
  Width := 800;
  Height := 500;
  FShowToolbar := True;
  FActiveIndex := -1;
  FShellPath := 'powershell.exe -NoLogo -NoExit';
  FSessions := TObjectList<TShellSession>.Create(False);

  FTermFont := TFont.Create;
  if Screen.Fonts.IndexOf('Cascadia Mono') >= 0 then
    FTermFont.Name := 'Cascadia Mono'
  else
    FTermFont.Name := 'Consolas';
  FTermFont.Size := 10;

  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := cToolbarH;
  FToolbar.BevelOuter := bvNone;
  FToolbar.ParentBackground := False;
  FToolbar.Color := clSdToolbar;

  FToolbarLine := TPanel.Create(Self);
  FToolbarLine.Parent := FToolbar;
  FToolbarLine.Align := alBottom;
  FToolbarLine.Height := 1;
  FToolbarLine.BevelOuter := bvNone;
  FToolbarLine.ParentBackground := False;
  FToolbarLine.Color := clSdBorder;

  FBtnNova := TShellToolButton.Create(Self);
  FBtnNova.Parent := FToolbar;
  FBtnNova.SetBounds(10, 7, 96, 26);
  FBtnNova.Caption := 'Nova aba';
  FBtnNova.OnClick := BtnNovaClick;

  FBtnClaude := TShellToolButton.Create(Self);
  FBtnClaude.Parent := FToolbar;
  FBtnClaude.SetBounds(112, 7, 110, 26);
  FBtnClaude.Caption := 'Claude Code';
  FBtnClaude.Accent := True;
  FBtnClaude.OnClick := BtnClaudeClick;

  FBtnFechar := TShellToolButton.Create(Self);
  FBtnFechar.Parent := FToolbar;
  FBtnFechar.SetBounds(228, 7, 96, 26);
  FBtnFechar.Caption := 'Fechar aba';
  FBtnFechar.OnClick := BtnFecharClick;

  FBtnPasta := TShellToolButton.Create(Self);
  FBtnPasta.Parent := FToolbar;
  FBtnPasta.SetBounds(330, 7, 96, 26);
  FBtnPasta.Caption := 'Pasta...';
  FBtnPasta.OnClick := BtnPastaClick;

  FTabs := TShellTabStrip.Create(Self);
  FTabs.FShell := Self;
  FTabs.Parent := Self;
  FTabs.Align := alTop;

  FClient := TPanel.Create(Self);
  FClient.Parent := Self;
  FClient.Align := alClient;
  FClient.BevelOuter := bvNone;
  FClient.ParentBackground := False;
  FClient.Color := clSdBack;
end;

destructor TShellDelphi.Destroy;
begin
  CloseAll;
  FSessions.Free;
  FTermFont.Free;
  inherited;
end;

procedure TShellDelphi.Loaded;
begin
  inherited;
  FToolbar.Visible := FShowToolbar;
end;

procedure TShellDelphi.SetShowToolbar(const V: Boolean);
begin
  FShowToolbar := V;
  if Assigned(FToolbar) then FToolbar.Visible := V;
end;

procedure TShellDelphi.SetTermFont(const V: TFont);
begin
  FTermFont.Assign(V);
end;

function TShellDelphi.GetSessionCount: Integer;
begin
  Result := FSessions.Count;
end;

function TShellDelphi.GetSession(Index: Integer): TShellSession;
begin
  Result := FSessions[Index];
end;

function TShellDelphi.GetActiveSession: TShellSession;
begin
  if (FActiveIndex >= 0) and (FActiveIndex < FSessions.Count) then
    Result := FSessions[FActiveIndex]
  else
    Result := nil;
end;

procedure TShellDelphi.ActivateTab(AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex >= FSessions.Count) then Exit;
  FActiveIndex := AIndex;
  for I := 0 to FSessions.Count - 1 do
    FSessions[I].Terminal.Visible := I = AIndex;
  FTabs.Invalidate;
  FSessions[AIndex].Focus;
end;

function TShellDelphi.NewTab(const ACaption, ACommandLine, AWorkDir: string): TShellSession;
var
  Cap, Cmd, Dir: string;
  Err: Cardinal;
begin
  if not TConPty.Supported then
    raise Exception.Create('ConPTY indisponivel. Requer Windows 10 1809 ou superior.');

  Cap := ACaption;
  if Cap = '' then Cap := Format('Shell %d', [FSessions.Count + 1]);

  Cmd := ACommandLine;
  if Cmd = '' then Cmd := FShellPath;

  Dir := AWorkDir;
  if Dir = '' then Dir := DirParaNovaAba;

  Result := TShellSession.Create(Self, Cap);
  FSessions.Add(Result);
  ActivateTab(FSessions.Count - 1);

  if not Result.Start(Cmd, Dir) then
  begin
    // le o erro antes de limpar: Free/Invalidate sobrescrevem o ultimo erro
    Err := GetLastError;
    // sem OnTabClosed: esta aba nunca chegou a abrir
    RemoveSessionEx(Result, False);
    raise Exception.CreateFmt('Falha ao iniciar "%s" em "%s". Codigo do erro: %d',
      [Cmd, Dir, Err]);
  end;

  if FStartupCommand <> '' then
    Result.SendCommand(FStartupCommand);

  FTabs.Invalidate;
  if Assigned(FOnTabOpened) then FOnTabOpened(Self, Result);
end;

// Pasta da proxima aba. Se o usuario fixou pelo botao "Pasta...", manda ele;
// senao pergunta ao hospedeiro, que responde com o projeto ativo do momento.
function TShellDelphi.DirParaNovaAba: string;
begin
  if FWorkDirFixo and (FWorkDir <> '') then
    Exit(FWorkDir);

  Result := '';
  if Assigned(FOnGetWorkDir) then
    FOnGetWorkDir(Self, Result);

  if (Result = '') or (not DirectoryExists(Result)) then
    Result := FWorkDir;
  if (Result = '') or (not DirectoryExists(Result)) then
    Result := GetCurrentDir;

  FWorkDir := Result;
end;

// Localiza o claude.exe sem depender do PATH herdado pelo processo da IDE,
// que costuma estar desatualizado se o Claude Code foi instalado depois.
function TShellDelphi.ResolveClaudeExe: string;
var
  Buf: array[0..MAX_PATH] of Char;
  P: PChar;
  Candidatos: array[0..2] of string;
  I: Integer;
  N: Cardinal;
begin
  if FClaudePath <> '' then
    Exit(FClaudePath);

  // SearchPath retorna >0 tambem quando o buffer NAO coube (ai o valor e o
  // tamanho necessario e Buf fica sem conteudo): so aceitar se coube.
  P := nil;
  N := SearchPath(nil, 'claude.exe', nil, Length(Buf), Buf, P);
  if (N > 0) and (N < Cardinal(Length(Buf))) then
    Exit(Buf);

  Candidatos[0] := GetEnvironmentVariable('USERPROFILE') + '\.local\bin\claude.exe';
  Candidatos[1] := GetEnvironmentVariable('APPDATA') + '\npm\claude.cmd';
  Candidatos[2] := GetEnvironmentVariable('LOCALAPPDATA') + '\Programs\claude\claude.exe';
  for I := Low(Candidatos) to High(Candidatos) do
    if FileExists(Candidatos[I]) then
      Exit(Candidatos[I]);

  Result := 'claude';
end;

function TShellDelphi.NewClaudeTab(const AWorkDir: string): TShellSession;
var
  Dir, Exe: string;
begin
  Dir := AWorkDir;
  if Dir = '' then Dir := DirParaNovaAba;

  Exe := ResolveClaudeExe;
  Result := NewTab('Claude',
    Format('powershell.exe -NoLogo -NoExit -Command "& ""%s"""', [Exe]), Dir);
end;

// Trata o pedido adiado vindo de PtyExit. A sessao pode ter sido fechada na
// mao nesse meio tempo, por isso a checagem antes de remover.
procedure TShellDelphi.CMShellRemove(var Msg: TMessage);
var
  S: TShellSession;
begin
  S := TShellSession(Msg.LParam);
  if FSessions.IndexOf(S) >= 0 then
    RemoveSession(S);
end;

procedure TShellDelphi.RemoveSession(ASession: TShellSession);
begin
  RemoveSessionEx(ASession, True);
end;

procedure TShellDelphi.RemoveSessionEx(ASession: TShellSession; ANotify: Boolean);
var
  Idx: Integer;
begin
  if ASession = nil then Exit;
  if ANotify and Assigned(FOnTabClosed) then FOnTabClosed(Self, ASession);

  Idx := FSessions.IndexOf(ASession);
  FSessions.Remove(ASession);
  ASession.Free;

  if FSessions.Count = 0 then
    FActiveIndex := -1
  else
  begin
    if Idx >= FSessions.Count then Idx := FSessions.Count - 1;
    if Idx < 0 then Idx := 0;
    ActivateTab(Idx);
  end;
  if Assigned(FTabs) then FTabs.Invalidate;
end;

procedure TShellDelphi.CloseTab(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FSessions.Count) then Exit;
  RemoveSession(FSessions[AIndex]);
end;

procedure TShellDelphi.CloseActiveTab;
begin
  RemoveSession(GetActiveSession);
end;

procedure TShellDelphi.CloseAll;
begin
  while FSessions.Count > 0 do
    RemoveSession(FSessions[FSessions.Count - 1]);
end;

procedure TShellDelphi.SendToActive(const ACommand: string);
var
  S: TShellSession;
begin
  S := GetActiveSession;
  if Assigned(S) then S.SendCommand(ACommand);
end;

procedure TShellDelphi.BtnNovaClick(Sender: TObject);
begin
  NewTab;
end;

procedure TShellDelphi.BtnClaudeClick(Sender: TObject);
begin
  NewClaudeTab;
end;

procedure TShellDelphi.BtnFecharClick(Sender: TObject);
begin
  CloseActiveTab;
end;

// Escolhe a pasta de trabalho das PROXIMAS abas. Existe porque a deteccao
// automatica depende de qual projeto a IDE considera ativo, que nem sempre
// e o que a pessoa esta editando.
procedure TShellDelphi.BtnPastaClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := FWorkDir;
  if Dir = '' then Dir := GetCurrentDir;
  if SelectDirectory('Pasta de trabalho das novas abas:', '', Dir) then
  begin
    FWorkDir := Dir;
    FWorkDirFixo := True;   // escolha manual vence a deteccao automatica
  end;
end;

{ ---------------------------------------------------------------- host externo }

function LaunchShellDelphiHost(const AWorkDir: string; AClaude: Boolean;
  const AHostExe: string): Boolean;
var
  Exe, Dir, Cmd: string;
  Si: TStartupInfo;
  Pi: TProcessInformation;
  Buf: array of Char;
begin
  Exe := AHostExe;
  if Exe = '' then
    Exe := ExtractFilePath(ParamStr(0)) + 'ShellDelphiHost.exe';
  if not FileExists(Exe) then
    raise Exception.CreateFmt('ShellDelphiHost.exe nao encontrado em: %s', [Exe]);

  Dir := AWorkDir;
  if Dir = '' then Dir := GetCurrentDir;

  Cmd := Format('"%s" "%s"', [Exe, Dir]);
  if AClaude then Cmd := Cmd + ' /claude';

  SetLength(Buf, Length(Cmd) + 1);
  Move(PChar(Cmd)^, Buf[0], Length(Cmd) * SizeOf(Char));
  Buf[Length(Cmd)] := #0;

  FillChar(Si, SizeOf(Si), 0);
  Si.cb := SizeOf(Si);
  FillChar(Pi, SizeOf(Pi), 0);

  Result := CreateProcess(nil, PChar(@Buf[0]), nil, nil, False,
    CREATE_NEW_PROCESS_GROUP, nil, PChar(Dir), Si, Pi);

  if Result then
  begin
    CloseHandle(Pi.hThread);
    CloseHandle(Pi.hProcess);
  end;
end;

procedure Register;
begin
  RegisterComponents('ShellDelphi', [TShellDelphi, TShellTerminal]);
end;

end.
