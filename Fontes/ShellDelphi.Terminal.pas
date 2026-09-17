unit ShellDelphi.Terminal;

// ShellDelphi - controle VCL de terminal: emulador VT100/xterm + renderizacao.
// Suporta: SGR (16/256/truecolor), cursor, regiao de rolagem, tela alternativa,
// scrollback, selecao/copia, teclado completo e bracketed paste.
// Delphi 10.2.3 Tokyo / Win32 / ASCII puro.

interface

// COMPAT - Resumo breve: compilavel do Delphi 10.2 Tokyo ate o Delphi 13.
// Nada aqui depende de RTL especifico de versao; os poucos identificadores
// que podem faltar nas versoes antigas sao declarados condicionalmente.
{$IF CompilerVersion < 32.0}
  {$MESSAGE ERROR 'ShellDelphi requer Delphi 10.2 Tokyo ou superior.'}
{$IFEND}
// COMPAT - Final

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Clipbrd, Vcl.Imaging.pngimage, Winapi.ShellAPI, System.IOUtils;

type
  TTermFlag = (tfBold, tfFaint, tfItalic, tfUnderline, tfInverse, tfHidden, tfStrike);
  TTermFlags = set of TTermFlag;

  // Cor: -1 = padrao, 0..255 = indice da paleta, >= $1000000 = truecolor ($1000000 or RGB)
  TTermColor = Integer;

  TTermAttr = record
    FG: TTermColor;
    BG: TTermColor;
    Flags: TTermFlags;
  end;

  TTermCell = record
    Ch: WideChar;
    A: TTermAttr;
  end;

  TTermLine = TArray<TTermCell>;

  TTermSendEvent = procedure(Sender: TObject; const Data: TBytes) of object;
  TTermResizeEvent = procedure(Sender: TObject; ACols, ARows: Integer) of object;

  TParserState = (psGround, psEsc, psCsi, psOsc, psStr, psCharset);

  TShellTerminal = class(TCustomControl)
  private
    // --- buffers
    FScreen: TArray<TTermLine>;
    FAltScreen: TArray<TTermLine>;
    FScrollback: TList<TTermLine>;
    FCols, FRows: Integer;
    FMaxScrollback: Integer;
    FUseAlt: Boolean;

    // --- cursor / estado
    FCX, FCY: Integer;
    FSavedCX, FSavedCY: Integer;
    FSavedAttr: TTermAttr;
    FAttr: TTermAttr;
    FScrollTop, FScrollBot: Integer;
    FWrapNext: Boolean;
    FAutoWrap: Boolean;
    FCursorVisible: Boolean;
    FAppCursorKeys: Boolean;
    FAppKeypad: Boolean;
    FBracketedPaste: Boolean;
    FMouseMode: Integer;    // 0=off, 1000/1002/1003
    // DIAG - contadores para o Ctrl+Shift+D
    FDbgHist: Integer;      // linhas que entraram no scrollback
    FDbgClear3J: Integer;   // vezes que o programa pediu ESC[3J
    FDbgStbm: Integer;      // vezes que o programa definiu DECSTBM
    FDbgWheel: Integer;     // eventos de roda que chegaram ao filtro
    FDbgWheelStep: Integer; // passos de rolagem efetivamente aplicados
    FWheelAcc: Integer;     // acumulador de WHEEL_DELTA
    // DIAG - Final
    FMouseSgr: Boolean;     // modo 1006 (coordenadas SGR)
    FTitle: string;

    // --- parser
    FState: TParserState;
    FParams: array[0..31] of Integer;
    FParamCount: Integer;
    FParamHasValue: Boolean;
    FPrivate: Char;
    FInterm: Char;
    FStrBuf: string;
    FUtf8Pend: TBytes;

    // --- render
    FCharW, FCharH: Integer;
    FTopLine: Integer;
    FAtBottom: Boolean;
    FSbWidth: Integer;
    FSbDragging: Boolean;
    FSbGrabOffset: Integer;
    FRepaintTimer: TTimer;
    FDirty: Boolean;
    FDefaultFG, FDefaultBG: TColor;
    FCursorColor: TColor;
    FPalette: array[0..255] of TColor;

    // --- selecao
    FSuppressNextChar: Boolean;   // ver KeyDown/KeyPress
    FSelecting: Boolean;
    FSelA, FSelB: TPoint;   // X = coluna, Y = linha absoluta
    FHasSel: Boolean;

    FOnSend: TTermSendEvent;
    FOnResizeTerm: TTermResizeEvent;
    FOnTitle: TNotifyEvent;

    procedure BuildPalette;
    procedure RecalcMetrics;
    procedure UpdateScrollBar;
    function SbTrackRect: TRect;
    function SbThumbRect: TRect;
    function MaxTopLine: Integer;
    procedure RepaintTick(Sender: TObject);
    procedure Invalidate2;

    function NewLine(ACols: Integer): TTermLine;
    procedure AllocBuffers(ACols, ARows: Integer);
    function TotalLines: Integer;
    function GetLineAbs(AIndex: Integer): TTermLine;
    function ResolveColor(C: TTermColor; ADefault: TColor): TColor;

    // --- emulador
    procedure FeedChar(C: WideChar);
    procedure PutChar(C: WideChar);
    procedure DoLineFeed;
    procedure DoReverseIndex;
    procedure ScrollRegionUp(N: Integer; AHistory: Boolean = True);
    procedure ScrollRegionDown(N: Integer);
    procedure EraseLineRange(Y, X1, X2: Integer);
    procedure CsiDispatch(Final: Char);
    procedure ApplySgr;
    procedure SetPrivateMode(Mode: Integer; Enable: Boolean);
    procedure SwitchAltScreen(Enable: Boolean);
    procedure OscDispatch;
    function Param(Index, Default: Integer): Integer;
    procedure ClampCursor;

    // --- entrada
    procedure SendStr(const S: string);
    procedure SendMouse(ABtn, X, Y: Integer; APress: Boolean);
    procedure SendBytes(const B: TBytes);
    function SelectionText: string;
    procedure ClearSelection;
    function PointToCell(X, Y: Integer): TPoint;

    function SaveClipboardImage: string;
    procedure SendPaths(AFiles: TStrings);
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    // INPUT-FIX - filtro de mensagens da aplicacao (roda do mouse e teclado)
    function HandleAppMessage(var Msg: TMsg): Boolean;
    // INPUT-FIX - Final
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    // ESC-FIX - IDE engolia teclas de dialogo (ESC/Tab/setas)
    procedure CMDialogKey(var Msg: TCMDialogKey); message CM_DIALOGKEY;
    procedure CMWantSpecialKey(var Msg: TCMWantSpecialKey); message CM_WANTSPECIALKEY;
    // ESC-FIX - Final
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure CMFocusChanged(var Msg: TMessage); message CM_FOCUSCHANGED;
    procedure SetDefaultBG(const V: TColor);
    procedure SetDefaultFG(const V: TColor);
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure Paint; override;
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheelDown(Shift: TShiftState; MousePos: TPoint): Boolean; override;
    function DoMouseWheelUp(Shift: TShiftState; MousePos: TPoint): Boolean; override;
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Alimenta o emulador com bytes crus vindos do ConPTY
    procedure Feed(const Data: TBytes);
    procedure Reset;
    procedure ClearScrollback;
    procedure CopySelection;
    procedure SelectAll;
    procedure PasteFromClipboard;
    procedure ScrollToBottom;
    // SCROLLBAR-FIX - rolagem por N linhas, usada pela barra e pelo teclado
    procedure ScrollLines(ADelta: Integer);
    // DIAG - despeja o estado interno do scroll na tela
    procedure DumpDiag;
    // DIAG - Final
    // Texto visivel da tela. Util para diagnostico e para testes automatizados.
    function ScreenText: string;

    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property Title: string read FTitle;
  published
    property Align;
    property Anchors;
    property Color;
    property Font;
    property PopupMenu;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property DefaultFG: TColor read FDefaultFG write SetDefaultFG default $00D4D4D4;
    property DefaultBG: TColor read FDefaultBG write SetDefaultBG default $001E1E1E;
    property CursorColor: TColor read FCursorColor write FCursorColor default $00D4D4D4;
    property MaxScrollback: Integer read FMaxScrollback write FMaxScrollback default 5000;
    property OnSend: TTermSendEvent read FOnSend write FOnSend;
    property OnResizeTerm: TTermResizeEvent read FOnResizeTerm write FOnResizeTerm;
    property OnTitle: TNotifyEvent read FOnTitle write FOnTitle;
    property OnKeyDown;
    property OnEnter;
    property OnExit;
  end;

implementation

const
  ESC = #27;

// COMPAT - WM_MOUSEHWHEEL nem sempre esta declarado em Winapi.Messages
{$IF not declared(WM_MOUSEHWHEEL)}
const
  WM_MOUSEHWHEEL = $020E;
{$IFEND}
// COMPAT - Final

// INPUT-FIX - Resumo breve: filtro unico de Application.OnMessage compartilhado
// por todos os terminais vivos. Nao usamos TApplicationEvents porque o
// TMultiCaster da VCL sobrescreve OnMessage, OnIdle, OnException e OnShortCut
// da aplicacao sem preservar handlers ja instalados - dentro da IDE isso
// desliga comportamento de terceiros. Aqui encadeamos: guardamos o handler
// anterior e o chamamos quando nenhum terminal trata a mensagem.
var
  GTerminals: TList<TShellTerminal> = nil;
  GPrevAppMessage: TMessageEvent = nil;
  GHookInstalled: Boolean = False;

type
  TAppMessageHook = class
    class procedure AppMessage(var Msg: TMsg; var Handled: Boolean);
  end;

class procedure TAppMessageHook.AppMessage(var Msg: TMsg; var Handled: Boolean);
var
  I: Integer;
begin
  // SHUTDOWN-FIX - este filtro roda para TODA mensagem da IDE. Uma excecao
  // escapando daqui derruba o RAD Studio inteiro, e no encerramento os objetos
  // vao sendo liberados numa ordem que nao controlamos. O try garante que, no
  // pior caso, a mensagem apenas deixa de ser tratada por nos.
  try
    // no encerramento o Application e liberado antes dos forms; a partir dai
    // nao tocamos em mais nada nosso
    if (Application = nil) or Application.Terminated then
      Exit;

    if not Handled and (GTerminals <> nil) then
      // de tras para frente: o terminal criado por ultimo tem prioridade e a
      // lista pode encolher se um terminal for destruido durante o despacho
      for I := GTerminals.Count - 1 downto 0 do
      begin
        if (GTerminals = nil) or (I >= GTerminals.Count) then Break;
        if GTerminals[I].HandleAppMessage(Msg) then
        begin
          Handled := True;
          Exit;
        end;
      end;
  except
    // filtro global: engolir e seguir e melhor do que derrubar a IDE
  end;

  // encadeia com quem estava instalado antes de nos
  if Assigned(GPrevAppMessage) then
    try
      GPrevAppMessage(Msg, Handled);
    except
      // o handler anterior pode pertencer a um objeto ja liberado
    end;
end;

procedure HookAppMessage(ATerm: TShellTerminal);
begin
  if GTerminals = nil then
    GTerminals := TList<TShellTerminal>.Create;
  if GTerminals.IndexOf(ATerm) < 0 then
    GTerminals.Add(ATerm);

  // SHUTDOWN-FIX - sem Application nao ha o que enganchar
  if (not GHookInstalled) and (Application <> nil) then
  begin
    GPrevAppMessage := Application.OnMessage;
    Application.OnMessage := TAppMessageHook.AppMessage;
    GHookInstalled := True;
  end;
end;

procedure UnhookAppMessage(ATerm: TShellTerminal);
begin
  if GTerminals <> nil then
    GTerminals.Remove(ATerm);

  if not GHookInstalled then Exit;
  if (GTerminals <> nil) and (GTerminals.Count > 0) then Exit;

  // SHUTDOWN-FIX - Application ja pode ter sido liberado quando o ultimo
  // terminal e destruido; ler OnMessage aqui era o Access Violation em
  // 'Read of address 00000010'
  if Application <> nil then
    // so restaura se ninguem instalou outro filtro por cima do nosso; se
    // instalou, desmontar aqui derrubaria o filtro alheio
    if @Application.OnMessage = @TAppMessageHook.AppMessage then
      Application.OnMessage := GPrevAppMessage;

  GPrevAppMessage := nil;
  GHookInstalled := False;
end;
// INPUT-FIX - Final

{ TShellTerminal }

constructor TShellTerminal.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque, csCaptureMouse, csDoubleClicks];
  DoubleBuffered := True;
  TabStop := True;
  Width := 640;
  Height := 400;

  FDefaultFG := $00CCCCCC;
  FDefaultBG := $001E1E1E;
  FCursorColor := $00ADAFAE;
  FMaxScrollback := 5000;
  Color := FDefaultBG;

  // fonte de terminal moderna quando disponivel
  if Screen.Fonts.IndexOf('Cascadia Mono') >= 0 then
    Font.Name := 'Cascadia Mono'
  else if Screen.Fonts.IndexOf('Consolas') >= 0 then
    Font.Name := 'Consolas'
  else
    Font.Name := 'Courier New';
  Font.Size := 10;
  Font.Color := FDefaultFG;

  BuildPalette;

  FScrollback := TList<TTermLine>.Create;
  FCols := 80;
  FRows := 25;
  FAttr.FG := -1;
  FAttr.BG := -1;
  FAttr.Flags := [];
  FAutoWrap := True;
  FCursorVisible := True;
  FAtBottom := True;

  // SCROLLBAR-FIX - barra mais larga: 10px era dificil de acertar com o mouse
  FSbWidth := 14;

  // INPUT-FIX - dentro do RAD Studio a IDE consome ESC e a roda do mouse antes
  // do controle. Instalamos um filtro na fila de mensagens da aplicacao.
  HookAppMessage(Self);
  // INPUT-FIX - Final

  FRepaintTimer := TTimer.Create(Self);
  FRepaintTimer.Interval := 33;
  FRepaintTimer.OnTimer := RepaintTick;
  FRepaintTimer.Enabled := True;

  AllocBuffers(FCols, FRows);
  FScrollTop := 0;
  FScrollBot := FRows - 1;
end;

destructor TShellTerminal.Destroy;
begin
  // SHUTDOWN-FIX - sair do filtro e a primeira coisa, e nunca pode lancar:
  // um destrutor que levanta excecao durante o fechamento da IDE vira Access
  // Violation sem origem aparente
  try
    UnhookAppMessage(Self);
  except
    // nada a fazer: estamos encerrando de qualquer forma
  end;
  FRepaintTimer.Enabled := False;
  FScrollback.Free;
  inherited;
end;

procedure TShellTerminal.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := Params.Style or WS_CLIPCHILDREN;
end;

procedure TShellTerminal.BuildPalette;
const
  Base: array[0..15] of TColor = (
    $00000000, $003131CD, $0079BC0D, $0010E5E5, $00C87224, $00BC3FBC, $00CDA811, $00E5E5E5,
    $00666666, $004C4CF1, $008BD123, $0043F5F5, $00EA8E3B, $00D670D6, $00DBB829, $00E5E5E5);
var
  I, R, G, B, V: Integer;

  function Cube(N: Integer): Integer;
  begin
    if N = 0 then Result := 0 else Result := 55 + N * 40;
  end;

begin
  for I := 0 to 15 do
    FPalette[I] := Base[I];
  // cubo 6x6x6
  for R := 0 to 5 do
    for G := 0 to 5 do
      for B := 0 to 5 do
      begin
        I := 16 + R * 36 + G * 6 + B;
        FPalette[I] := RGB(Cube(R), Cube(G), Cube(B));
      end;
  // escala de cinza
  for I := 0 to 23 do
  begin
    V := 8 + I * 10;
    FPalette[232 + I] := RGB(V, V, V);
  end;
end;

procedure TShellTerminal.SetDefaultFG(const V: TColor);
begin
  FDefaultFG := V;
  Invalidate2;
end;

procedure TShellTerminal.SetDefaultBG(const V: TColor);
begin
  FDefaultBG := V;
  Color := V;
  Invalidate2;
end;

function TShellTerminal.NewLine(ACols: Integer): TTermLine;
var
  I: Integer;
begin
  SetLength(Result, ACols);
  for I := 0 to ACols - 1 do
  begin
    Result[I].Ch := ' ';
    Result[I].A.FG := -1;
    Result[I].A.BG := -1;
    Result[I].A.Flags := [];
  end;
end;

procedure TShellTerminal.AllocBuffers(ACols, ARows: Integer);
var
  Old: TArray<TTermLine>;
  OldRows, I, J, Copy_: Integer;
  WasFull: Boolean;
begin
  Old := FScreen;
  OldRows := Length(Old);
  SetLength(FScreen, ARows);
  for I := 0 to ARows - 1 do
  begin
    FScreen[I] := NewLine(ACols);
    if I < OldRows then
    begin
      Copy_ := Length(Old[I]);
      if Copy_ > ACols then Copy_ := ACols;
      for J := 0 to Copy_ - 1 do
        FScreen[I][J] := Old[I][J];
    end;
  end;

  // RESIZE-FIX - Resumo breve: a tela alternativa era sempre zerada. Redimensionar
  // o painel com vim ou htop aberto apagava o conteudo ate o programa repintar.
  // Copiamos o que cabe, como ja e feito com a tela principal.
  Old := FAltScreen;
  OldRows := Length(Old);
  SetLength(FAltScreen, ARows);
  for I := 0 to ARows - 1 do
  begin
    FAltScreen[I] := NewLine(ACols);
    if I < OldRows then
    begin
      Copy_ := Length(Old[I]);
      if Copy_ > ACols then Copy_ := ACols;
      for J := 0 to Copy_ - 1 do
        FAltScreen[I][J] := Old[I][J];
    end;
  end;

  // RESIZE-FIX - a regiao de rolagem (DECSTBM) era descartada no resize. Se ela
  // cobria a tela inteira, acompanha o novo tamanho; se era parcial, e do
  // programa e so precisa caber nos novos limites.
  WasFull := (FRows = 0) or ((FScrollTop = 0) and (FScrollBot = FRows - 1));

  FCols := ACols;
  FRows := ARows;

  if WasFull then
  begin
    FScrollTop := 0;
    FScrollBot := ARows - 1;
  end
  else
  begin
    if FScrollTop > ARows - 1 then FScrollTop := ARows - 1;
    if FScrollBot > ARows - 1 then FScrollBot := ARows - 1;
    if FScrollTop < 0 then FScrollTop := 0;
    if FScrollBot <= FScrollTop then
    begin
      FScrollTop := 0;
      FScrollBot := ARows - 1;
    end;
  end;
  ClampCursor;
end;

function TShellTerminal.TotalLines: Integer;
begin
  Result := FScrollback.Count + FRows;
end;

function TShellTerminal.GetLineAbs(AIndex: Integer): TTermLine;
begin
  if AIndex < FScrollback.Count then
    Result := FScrollback[AIndex]
  else
  begin
    AIndex := AIndex - FScrollback.Count;
    if (AIndex >= 0) and (AIndex < Length(FScreen)) then
    begin
      if FUseAlt then
        Result := FAltScreen[AIndex]
      else
        Result := FScreen[AIndex];
    end
    else
      Result := nil;
  end;
end;

// ---------------------------------------------------------------- emulador

procedure TShellTerminal.Feed(const Data: TBytes);
var
  Buf: TBytes;
  I, Len, Need: Integer;
  B: Byte;
  Cp: Cardinal;
  W: WideChar;
begin
  if Length(Data) = 0 then Exit;

  if Length(FUtf8Pend) > 0 then
  begin
    SetLength(Buf, Length(FUtf8Pend) + Length(Data));
    Move(FUtf8Pend[0], Buf[0], Length(FUtf8Pend));
    Move(Data[0], Buf[Length(FUtf8Pend)], Length(Data));
    SetLength(FUtf8Pend, 0);
  end
  else
    Buf := Data;

  Len := Length(Buf);
  I := 0;
  while I < Len do
  begin
    B := Buf[I];
    if B < $80 then
    begin
      FeedChar(WideChar(B));
      Inc(I);
      Continue;
    end;

    if (B and $E0) = $C0 then begin Need := 2; Cp := B and $1F; end
    else if (B and $F0) = $E0 then begin Need := 3; Cp := B and $0F; end
    else if (B and $F8) = $F0 then begin Need := 4; Cp := B and $07; end
    else begin FeedChar('?'); Inc(I); Continue; end;

    if I + Need > Len then
    begin
      // sequencia UTF-8 partida no limite do chunk: guarda para o proximo Feed
      SetLength(FUtf8Pend, Len - I);
      Move(Buf[I], FUtf8Pend[0], Len - I);
      Break;
    end;

    Cp := Cp;
    case Need of
      2: Cp := (Cp shl 6) or (Buf[I+1] and $3F);
      3: Cp := (((Cp shl 6) or (Buf[I+1] and $3F)) shl 6) or (Buf[I+2] and $3F);
      4: Cp := (((((Cp shl 6) or (Buf[I+1] and $3F)) shl 6) or (Buf[I+2] and $3F)) shl 6)
                 or (Buf[I+3] and $3F);
    end;
    Inc(I, Need);

    if Cp > $FFFF then
    begin
      // fora do BMP: substitui (celula e WideChar unico)
      FeedChar(#$FFFD);
    end
    else
    begin
      W := WideChar(Cp);
      FeedChar(W);
    end;
  end;

  FDirty := True;
end;

function TShellTerminal.Param(Index, Default: Integer): Integer;
begin
  if (Index >= 0) and (Index < FParamCount) and (FParams[Index] >= 0) then
    Result := FParams[Index]
  else
    Result := Default;
  // CSI trata parametro 0 como 1 nos comandos de movimento/contagem
  if (Result = 0) and (Default = 1) then
    Result := 1;
end;

procedure TShellTerminal.ClampCursor;
begin
  if FCX < 0 then FCX := 0;
  if FCX > FCols - 1 then FCX := FCols - 1;
  if FCY < 0 then FCY := 0;
  if FCY > FRows - 1 then FCY := FRows - 1;
end;

procedure TShellTerminal.FeedChar(C: WideChar);
var
  I: Integer;
begin
  case FState of
    psGround:
      begin
        case C of
          ESC:
            begin
              FState := psEsc;
              FStrBuf := '';
            end;
          #13: begin FCX := 0; FWrapNext := False; end;
          #10, #11, #12: DoLineFeed;
          #8: begin
                if FWrapNext then FWrapNext := False
                else if FCX > 0 then Dec(FCX);
              end;
          #9: begin
                I := ((FCX div 8) + 1) * 8;
                if I > FCols - 1 then I := FCols - 1;
                FCX := I;
                FWrapNext := False;
              end;
          #7: ; // bell
          #0: ;
        else
          if C >= ' ' then PutChar(C);
        end;
      end;

    psEsc:
      begin
        case C of
          '[': begin
                 FState := psCsi;
                 FParamCount := 0;
                 FParamHasValue := False;
                 FPrivate := #0;
                 FInterm := #0;
                 FillChar(FParams, SizeOf(FParams), 0);
                 for I := 0 to High(FParams) do FParams[I] := -1;
               end;
          ']': begin FState := psOsc; FStrBuf := ''; end;
          'P', 'X', '^', '_': begin FState := psStr; FStrBuf := ''; end;
          '(', ')', '*', '+', '-', '.', '/': FState := psCharset;
          '7': begin FSavedCX := FCX; FSavedCY := FCY; FSavedAttr := FAttr; FState := psGround; end;
          '8': begin FCX := FSavedCX; FCY := FSavedCY; FAttr := FSavedAttr; ClampCursor; FState := psGround; end;
          'D': begin DoLineFeed; FState := psGround; end;
          'E': begin FCX := 0; DoLineFeed; FState := psGround; end;
          'M': begin DoReverseIndex; FState := psGround; end;
          'c': begin Reset; FState := psGround; end;
          '=': begin FAppKeypad := True; FState := psGround; end;
          '>': begin FAppKeypad := False; FState := psGround; end;
        else
          FState := psGround;
        end;
      end;

    psCharset:
      FState := psGround;

    psCsi:
      begin
        if (C >= '0') and (C <= '9') then
        begin
          if FParamCount = 0 then FParamCount := 1;
          if FParams[FParamCount - 1] < 0 then FParams[FParamCount - 1] := 0;
          FParams[FParamCount - 1] := FParams[FParamCount - 1] * 10 + (Ord(C) - Ord('0'));
          FParamHasValue := True;
        end
        else if (C = ';') or (C = ':') then
        begin
          if FParamCount = 0 then FParamCount := 1;
          if FParamCount < High(FParams) then Inc(FParamCount);
          FParams[FParamCount - 1] := -1;
        end
        else if (C >= '<') and (C <= '?') then
          FPrivate := C
        else if (C >= ' ') and (C <= '/') then
          FInterm := C
        else if (C >= '@') and (C <= '~') then
        begin
          CsiDispatch(C);
          FState := psGround;
        end
        else
          FState := psGround;
      end;

    psOsc, psStr:
      begin
        if C = #7 then
        begin
          if FState = psOsc then OscDispatch;
          FState := psGround;
        end
        else if C = ESC then
          FStrBuf := FStrBuf + ESC
        else if (C = '\') and (Length(FStrBuf) > 0) and (FStrBuf[Length(FStrBuf)] = ESC) then
        begin
          SetLength(FStrBuf, Length(FStrBuf) - 1);
          if FState = psOsc then OscDispatch;
          FState := psGround;
        end
        else
          FStrBuf := FStrBuf + C;
      end;
  end;
end;

procedure TShellTerminal.PutChar(C: WideChar);
var
  Line: TTermLine;
begin
  if FWrapNext and FAutoWrap then
  begin
    FCX := 0;
    DoLineFeed;
    FWrapNext := False;
  end;
  ClampCursor;

  if FUseAlt then Line := FAltScreen[FCY] else Line := FScreen[FCY];
  Line[FCX].Ch := C;
  Line[FCX].A := FAttr;

  if FCX < FCols - 1 then
    Inc(FCX)
  else
    FWrapNext := True;
end;

procedure TShellTerminal.DoLineFeed;
begin
  FWrapNext := False;
  if FCY = FScrollBot then
    ScrollRegionUp(1)
  else if FCY < FRows - 1 then
    Inc(FCY);
end;

procedure TShellTerminal.DoReverseIndex;
begin
  FWrapNext := False;
  if FCY = FScrollTop then
    ScrollRegionDown(1)
  else if FCY > 0 then
    Dec(FCY);
end;

procedure TShellTerminal.ScrollRegionUp(N: Integer; AHistory: Boolean = True);
var
  Buf: TArray<TTermLine>;
  I, K: Integer;
  FullScreen: Boolean;
begin
  if N <= 0 then Exit;
  if FUseAlt then Buf := FAltScreen else Buf := FScreen;
  // SCROLLBACK-FIX - Resumo breve: so vira historico a linha que sai de uma
  // rolagem da tela inteira e que o chamador marcou como historico. Delete Line
  // (CSI M) reaproveita esta rotina mexendo em FScrollTop, mas e edicao no
  // lugar: nao pode empurrar nada para o scrollback.
  // A regiao precisa comecar no topo: nada existe acima dela, entao a linha que
  // sai e historico de verdade. NAO exigimos FScrollBot = FRows-1 porque
  // programas que fixam uma barra no rodape (Claude Code) definem DECSTBM com
  // rodape reservado, e exigir a tela inteira descartava todo o historico deles.
  // O AHistory protege o caso que essa folga abriria: edicao no lugar (CSI M).
  FullScreen := AHistory and (not FUseAlt) and (FScrollTop = 0);

  for K := 1 to N do
  begin
    if FullScreen then
    begin
      FScrollback.Add(Buf[FScrollTop]);
      Inc(FDbgHist);
      // SCROLLBACK-FIX - ao descartar a linha mais antiga todos os indices
      // absolutos andam um para tras; sem ajustar FTopLine e a selecao, a vista
      // congelada deriva e a copia sai deslocada do que esta marcado
      while FScrollback.Count > FMaxScrollback do
      begin
        FScrollback.Delete(0);
        if FTopLine > 0 then Dec(FTopLine);
        if FHasSel then
        begin
          Dec(FSelA.Y);
          Dec(FSelB.Y);
        end;
      end;
      // a linha que saiu da tela entra no scrollback com o MESMO indice
      // absoluto, entao a vista congelada nao se move: FTopLine fica parado
    end;
    for I := FScrollTop to FScrollBot - 1 do
      Buf[I] := Buf[I + 1];
    Buf[FScrollBot] := NewLine(FCols);
  end;
  FDirty := True;
end;

procedure TShellTerminal.ScrollRegionDown(N: Integer);
var
  Buf: TArray<TTermLine>;
  I, K: Integer;
begin
  if N <= 0 then Exit;
  if FUseAlt then Buf := FAltScreen else Buf := FScreen;
  for K := 1 to N do
  begin
    for I := FScrollBot downto FScrollTop + 1 do
      Buf[I] := Buf[I - 1];
    Buf[FScrollTop] := NewLine(FCols);
  end;
  FDirty := True;
end;

procedure TShellTerminal.EraseLineRange(Y, X1, X2: Integer);
var
  Line: TTermLine;
  I: Integer;
begin
  if (Y < 0) or (Y >= FRows) then Exit;
  if FUseAlt then Line := FAltScreen[Y] else Line := FScreen[Y];
  if X1 < 0 then X1 := 0;
  if X2 > FCols - 1 then X2 := FCols - 1;
  for I := X1 to X2 do
  begin
    Line[I].Ch := ' ';
    Line[I].A.FG := -1;
    Line[I].A.BG := FAttr.BG;
    Line[I].A.Flags := [];
  end;
end;

procedure TShellTerminal.CsiDispatch(Final: Char);
var
  N, I, T, B: Integer;
begin
  case Final of
    'A': begin FCY := FCY - Param(0, 1); if FCY < FScrollTop then FCY := FScrollTop; ClampCursor; FWrapNext := False; end;
    'B': begin FCY := FCY + Param(0, 1); if FCY > FScrollBot then FCY := FScrollBot; ClampCursor; FWrapNext := False; end;
    'C': begin FCX := FCX + Param(0, 1); ClampCursor; FWrapNext := False; end;
    'D': begin FCX := FCX - Param(0, 1); ClampCursor; FWrapNext := False; end;
    'E': begin FCY := FCY + Param(0, 1); FCX := 0; ClampCursor; FWrapNext := False; end;
    'F': begin FCY := FCY - Param(0, 1); FCX := 0; ClampCursor; FWrapNext := False; end;
    'G', '`': begin FCX := Param(0, 1) - 1; ClampCursor; FWrapNext := False; end;
    'd': begin FCY := Param(0, 1) - 1; ClampCursor; FWrapNext := False; end;
    'H', 'f':
      begin
        FCY := Param(0, 1) - 1;
        FCX := Param(1, 1) - 1;
        ClampCursor;
        FWrapNext := False;
      end;
    'J':
      begin
        N := Param(0, 0);
        case N of
          0: begin
               EraseLineRange(FCY, FCX, FCols - 1);
               for I := FCY + 1 to FRows - 1 do EraseLineRange(I, 0, FCols - 1);
             end;
          1: begin
               for I := 0 to FCY - 1 do EraseLineRange(I, 0, FCols - 1);
               EraseLineRange(FCY, 0, FCX);
             end;
          2: for I := 0 to FRows - 1 do EraseLineRange(I, 0, FCols - 1);
          3: begin Inc(FDbgClear3J); ClearScrollback; end;
        end;
        FDirty := True;
      end;
    'K':
      begin
        case Param(0, 0) of
          0: EraseLineRange(FCY, FCX, FCols - 1);
          1: EraseLineRange(FCY, 0, FCX);
          2: EraseLineRange(FCY, 0, FCols - 1);
        end;
        FDirty := True;
      end;
    'L':
      begin
        // insere linhas dentro da regiao, a partir do cursor
        T := FScrollTop; FScrollTop := FCY;
        ScrollRegionDown(Param(0, 1));
        FScrollTop := T;
      end;
    'M':
      begin
        T := FScrollTop; FScrollTop := FCY;
        // SCROLLBACK-FIX - DL e edicao no lugar, nunca historico
        ScrollRegionUp(Param(0, 1), False);
        FScrollTop := T;
      end;
    '@':
      begin
        N := Param(0, 1);
        for I := FCols - 1 downto FCX + N do
          if FUseAlt then FAltScreen[FCY][I] := FAltScreen[FCY][I - N]
          else FScreen[FCY][I] := FScreen[FCY][I - N];
        B := FCX + N - 1;
        if B > FCols - 1 then B := FCols - 1;
        EraseLineRange(FCY, FCX, B);
      end;
    'P':
      begin
        N := Param(0, 1);
        for I := FCX to FCols - 1 - N do
          if FUseAlt then FAltScreen[FCY][I] := FAltScreen[FCY][I + N]
          else FScreen[FCY][I] := FScreen[FCY][I + N];
        EraseLineRange(FCY, FCols - N, FCols - 1);
      end;
    'X':
      begin
        N := Param(0, 1);
        B := FCX + N - 1;
        if B > FCols - 1 then B := FCols - 1;
        EraseLineRange(FCY, FCX, B);
      end;
    'S': ScrollRegionUp(Param(0, 1));
    'T': ScrollRegionDown(Param(0, 1));
    'm': ApplySgr;
    'h':
      begin
        if FPrivate = '?' then
          for I := 0 to FParamCount - 1 do SetPrivateMode(Param(I, 0), True);
      end;
    'l':
      begin
        if FPrivate = '?' then
          for I := 0 to FParamCount - 1 do SetPrivateMode(Param(I, 0), False);
      end;
    'r':
      begin
        T := Param(0, 1) - 1;
        B := Param(1, FRows) - 1;
        if T < 0 then T := 0;
        if B > FRows - 1 then B := FRows - 1;
        if T < B then
        begin
          Inc(FDbgStbm);
          FScrollTop := T;
          FScrollBot := B;
          FCX := 0;
          FCY := T;
        end;
      end;
    's': begin FSavedCX := FCX; FSavedCY := FCY; FSavedAttr := FAttr; end;
    'u': begin FCX := FSavedCX; FCY := FSavedCY; FAttr := FSavedAttr; ClampCursor; end;
    'n':
      if Param(0, 0) = 6 then
        SendStr(Format('%s[%d;%dR', [ESC, FCY + 1, FCX + 1]));
    'c':
      SendStr(ESC + '[?1;2c');
  end;
end;

procedure TShellTerminal.ApplySgr;
var
  I, P: Integer;
begin
  if FParamCount = 0 then
  begin
    FAttr.FG := -1; FAttr.BG := -1; FAttr.Flags := [];
    Exit;
  end;
  I := 0;
  while I < FParamCount do
  begin
    P := Param(I, 0);
    if FParams[I] < 0 then P := 0;
    case P of
      0: begin FAttr.FG := -1; FAttr.BG := -1; FAttr.Flags := []; end;
      1: Include(FAttr.Flags, tfBold);
      2: Include(FAttr.Flags, tfFaint);
      3: Include(FAttr.Flags, tfItalic);
      4: Include(FAttr.Flags, tfUnderline);
      7: Include(FAttr.Flags, tfInverse);
      8: Include(FAttr.Flags, tfHidden);
      9: Include(FAttr.Flags, tfStrike);
      21, 22: FAttr.Flags := FAttr.Flags - [tfBold, tfFaint];
      23: Exclude(FAttr.Flags, tfItalic);
      24: Exclude(FAttr.Flags, tfUnderline);
      27: Exclude(FAttr.Flags, tfInverse);
      28: Exclude(FAttr.Flags, tfHidden);
      29: Exclude(FAttr.Flags, tfStrike);
      30..37: FAttr.FG := P - 30;
      39: FAttr.FG := -1;
      40..47: FAttr.BG := P - 40;
      49: FAttr.BG := -1;
      90..97: FAttr.FG := P - 90 + 8;
      100..107: FAttr.BG := P - 100 + 8;
      38, 48:
        begin
          if (I + 1 < FParamCount) and (Param(I + 1, 0) = 5) then
          begin
            if P = 38 then FAttr.FG := Param(I + 2, 0) and $FF
            else FAttr.BG := Param(I + 2, 0) and $FF;
            Inc(I, 2);
          end
          else if (I + 1 < FParamCount) and (Param(I + 1, 0) = 2) then
          begin
            if P = 38 then
              FAttr.FG := $1000000 or RGB(Param(I + 2, 0), Param(I + 3, 0), Param(I + 4, 0))
            else
              FAttr.BG := $1000000 or RGB(Param(I + 2, 0), Param(I + 3, 0), Param(I + 4, 0));
            Inc(I, 4);
          end;
        end;
    end;
    Inc(I);
  end;
end;

procedure TShellTerminal.SetPrivateMode(Mode: Integer; Enable: Boolean);
begin
  case Mode of
    1: FAppCursorKeys := Enable;
    7: FAutoWrap := Enable;
    25: FCursorVisible := Enable;
    1049, 1047, 47: SwitchAltScreen(Enable);
    2004: FBracketedPaste := Enable;
    1000, 1002, 1003:
      if Enable then FMouseMode := Mode else FMouseMode := 0;
    1006, 1015:
      FMouseSgr := Enable;
  end;
end;

procedure TShellTerminal.SwitchAltScreen(Enable: Boolean);
var
  I: Integer;
begin
  if Enable = FUseAlt then Exit;
  if Enable then
  begin
    FSavedCX := FCX; FSavedCY := FCY; FSavedAttr := FAttr;
    for I := 0 to FRows - 1 do
      FAltScreen[I] := NewLine(FCols);
    FUseAlt := True;
    FCX := 0; FCY := 0;
  end
  else
  begin
    FUseAlt := False;
    FCX := FSavedCX; FCY := FSavedCY; FAttr := FSavedAttr;
    ClampCursor;
  end;
  ScrollToBottom;
  FDirty := True;
end;

procedure TShellTerminal.OscDispatch;
var
  P: Integer;
  S: string;
begin
  S := FStrBuf;
  P := Pos(';', S);
  if P = 0 then Exit;
  if (Copy(S, 1, P - 1) = '0') or (Copy(S, 1, P - 1) = '2') then
  begin
    FTitle := Copy(S, P + 1, MaxInt);
    if Assigned(FOnTitle) then FOnTitle(Self);
  end;
end;

procedure TShellTerminal.Reset;
var
  I: Integer;
begin
  FAttr.FG := -1; FAttr.BG := -1; FAttr.Flags := [];
  FCX := 0; FCY := 0;
  FScrollTop := 0; FScrollBot := FRows - 1;
  FUseAlt := False;
  FAutoWrap := True;
  FCursorVisible := True;
  FAppCursorKeys := False;
  FState := psGround;
  for I := 0 to FRows - 1 do
    FScreen[I] := NewLine(FCols);
  ScrollToBottom;
  FDirty := True;
end;

procedure TShellTerminal.ClearScrollback;
begin
  FScrollback.Clear;
  ScrollToBottom;
  FDirty := True;
end;

// SCROLLBAR-FIX - Resumo breve: um unico ponto de rolagem do historico, usado
// pela barra, pelo teclado e pela roda. Negativo sobe, positivo desce.
procedure TShellTerminal.ScrollLines(ADelta: Integer);
var
  MaxTop: Integer;
begin
  MaxTop := MaxTopLine;
  if MaxTop <= 0 then Exit;

  FTopLine := FTopLine + ADelta;
  if FTopLine < 0 then FTopLine := 0;
  if FTopLine > MaxTop then FTopLine := MaxTop;
  FAtBottom := FTopLine >= MaxTop;
  FDirty := True;
end;

// DIAG - Resumo breve: imprime o estado que decide o caminho da roda do mouse.
// Nada e enviado ao processo; o texto e injetado no proprio emulador.
procedure TShellTerminal.DumpDiag;
var
  S: string;
  NTerm: Integer;
begin
  if GTerminals <> nil then NTerm := GTerminals.Count else NTerm := 0;
  S := #13#10 +
    '--- ShellDelphi diag ---' + #13#10 +
    Format('AltScreen=%s  MouseMode=%d  MouseSgr=%s  AppCursor=%s', [
      BoolToStr(FUseAlt, True), FMouseMode,
      BoolToStr(FMouseSgr, True), BoolToStr(FAppCursorKeys, True)]) + #13#10 +
    Format('Regiao: top=%d bot=%d   Tela: %dx%d', [
      FScrollTop, FScrollBot, FCols, FRows]) + #13#10 +
    Format('Scrollback=%d  TotalLines=%d  TopLine=%d  AtBottom=%s', [
      FScrollback.Count, TotalLines, FTopLine, BoolToStr(FAtBottom, True)]) + #13#10 +
    Format('Linhas p/ historico=%d   ESC[3J recebidos=%d   DECSTBM=%d', [
      FDbgHist, FDbgClear3J, FDbgStbm]) + #13#10 +
    Format('Roda: eventos=%d  passos=%d', [FDbgWheel, FDbgWheelStep]) + #13#10 +
    Format('Filtro instalado=%s  terminais=%d  Focado=%s', [
      BoolToStr(GHookInstalled, True),
      NTerm,
      BoolToStr(Focused, True)]) + #13#10 +
    '------------------------' + #13#10;
  Feed(TEncoding.UTF8.GetBytes(S));
end;
// DIAG - Final

function TShellTerminal.ScreenText: string;
var
  Y, X: Integer;
  Line: TTermLine;
  L: string;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for Y := 0 to FRows - 1 do
    begin
      if FUseAlt then Line := FAltScreen[Y] else Line := FScreen[Y];
      if Line = nil then Continue;
      SetLength(L, Length(Line));
      for X := 0 to Length(Line) - 1 do
        L[X + 1] := Line[X].Ch;
      while (L <> '') and (L[Length(L)] = ' ') do
        SetLength(L, Length(L) - 1);
      SB.AppendLine(L);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// ---------------------------------------------------------------- render

procedure TShellTerminal.RecalcMetrics;
var
  TM: TTextMetric;
begin
  Canvas.Font := Font;
  GetTextMetrics(Canvas.Handle, TM);
  FCharW := Canvas.TextWidth('W');
  if FCharW <= 0 then FCharW := TM.tmAveCharWidth;
  if FCharW <= 0 then FCharW := 8;
  FCharH := TM.tmHeight;
  if FCharH <= 0 then FCharH := 16;
end;

procedure TShellTerminal.Resize;
var
  NC, NR: Integer;
begin
  inherited;
  if not HandleAllocated then Exit;
  RecalcMetrics;
  NC := (ClientWidth - FSbWidth - 6) div FCharW;
  NR := ClientHeight div FCharH;
  if NC < 10 then NC := 10;
  if NR < 3 then NR := 3;
  if (NC <> FCols) or (NR <> FRows) then
  begin
    AllocBuffers(NC, NR);
    if Assigned(FOnResizeTerm) then FOnResizeTerm(Self, NC, NR);
  end;
  UpdateScrollBar;
  Invalidate2;
end;

function TShellTerminal.ResolveColor(C: TTermColor; ADefault: TColor): TColor;
begin
  if C < 0 then
    Result := ADefault
  else if C >= $1000000 then
    Result := TColor(C and $FFFFFF)
  else
    Result := FPalette[C and $FF];
end;

procedure TShellTerminal.Paint;
var
  Y, X, RunStart, AbsLine: Integer;
  Line: TTermLine;
  A: TTermAttr;
  FG, BG, Tmp: TColor;
  S: string;
  R: TRect;
  CurAbs: Integer;
  SelLo, SelHi: TPoint;
  InSel: Boolean;

  function SameAttr(const A1, A2: TTermAttr): Boolean;
  begin
    Result := (A1.FG = A2.FG) and (A1.BG = A2.BG) and (A1.Flags = A2.Flags);
  end;

  function CellSelected(ACol, ARow: Integer): Boolean;
  begin
    Result := False;
    if not FHasSel then Exit;
    if (ARow < SelLo.Y) or (ARow > SelHi.Y) then Exit;
    if (ARow = SelLo.Y) and (ACol < SelLo.X) then Exit;
    if (ARow = SelHi.Y) and (ACol >= SelHi.X) then Exit;
    Result := True;
  end;

  procedure FlushRun(ARow, AFrom, ATo: Integer; const AA: TTermAttr; ASel: Boolean);
  var
    K: Integer;
  begin
    if ATo < AFrom then Exit;
    FG := ResolveColor(AA.FG, FDefaultFG);
    BG := ResolveColor(AA.BG, FDefaultBG);
    if tfInverse in AA.Flags then
    begin
      Tmp := FG; FG := BG; BG := Tmp;
    end;
    if ASel then
    begin
      Tmp := FG; FG := BG; BG := Tmp;
    end;
    if tfHidden in AA.Flags then FG := BG;

    Canvas.Font := Font;
    Canvas.Font.Color := FG;
    if tfBold in AA.Flags then Canvas.Font.Style := Canvas.Font.Style + [fsBold];
    if tfItalic in AA.Flags then Canvas.Font.Style := Canvas.Font.Style + [fsItalic];
    if tfUnderline in AA.Flags then Canvas.Font.Style := Canvas.Font.Style + [fsUnderline];
    if tfStrike in AA.Flags then Canvas.Font.Style := Canvas.Font.Style + [fsStrikeOut];
    Canvas.Brush.Color := BG;
    Canvas.Brush.Style := bsSolid;

    R := Rect(AFrom * FCharW, ARow * FCharH, (ATo + 1) * FCharW, (ARow + 1) * FCharH);
    SetLength(S, ATo - AFrom + 1);
    for K := AFrom to ATo do
      S[K - AFrom + 1] := Line[K].Ch;
    Canvas.TextRect(R, R.Left, R.Top, S);
  end;

begin
  if FCharW = 0 then RecalcMetrics;

  // PAINT-FIX - Resumo breve: pintar a largura inteira, inclusive a calha da
  // barra. A calha so e desenhada quando ha scrollback e o WMEraseBkgnd nao
  // apaga nada; com DoubleBuffered o VCL entrega um bitmap novo a cada pintura,
  // entao sem historico sobrava uma faixa de lixo na borda direita.
  Canvas.Brush.Color := FDefaultBG;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(Rect(0, 0, ClientWidth, ClientHeight));

  if FHasSel then
  begin
    if (FSelA.Y < FSelB.Y) or ((FSelA.Y = FSelB.Y) and (FSelA.X <= FSelB.X)) then
    begin
      SelLo := FSelA; SelHi := FSelB;
    end
    else
    begin
      SelLo := FSelB; SelHi := FSelA;
    end;
  end;

  for Y := 0 to FRows - 1 do
  begin
    AbsLine := FTopLine + Y;
    if AbsLine >= TotalLines then Break;
    Line := GetLineAbs(AbsLine);
    if Line = nil then Continue;

    RunStart := 0;
    A := Line[0].A;
    InSel := CellSelected(0, AbsLine);
    for X := 1 to Length(Line) - 1 do
    begin
      if (not SameAttr(Line[X].A, A)) or (CellSelected(X, AbsLine) <> InSel) then
      begin
        FlushRun(Y, RunStart, X - 1, A, InSel);
        RunStart := X;
        A := Line[X].A;
        InSel := CellSelected(X, AbsLine);
      end;
    end;
    FlushRun(Y, RunStart, Length(Line) - 1, A, InSel);
  end;

  // barra de rolagem slim, desenhada pelo proprio controle (sem VCL themes)
  if MaxTopLine > 0 then
  begin
    // SCROLLBAR-FIX - mais contraste: a barra antiga quase sumia no fundo
    R := SbTrackRect;
    Canvas.Brush.Color := $002D2D30;
    Canvas.FillRect(R);
    R := SbThumbRect;
    if not IsRectEmpty(R) then
    begin
      if FSbDragging then
        Canvas.Brush.Color := $009E9E9E
      else
        Canvas.Brush.Color := $00686868;
      Canvas.Pen.Color := Canvas.Brush.Color;
      Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 5, 5);
    end;
  end;

  // cursor
  if FCursorVisible then
  begin
    CurAbs := FScrollback.Count + FCY;
    Y := CurAbs - FTopLine;
    if (Y >= 0) and (Y < FRows) then
    begin
      R := Rect(FCX * FCharW, Y * FCharH, (FCX + 1) * FCharW, (Y + 1) * FCharH);
      if Focused then
      begin
        Canvas.Brush.Color := FCursorColor;
        Canvas.FillRect(R);
        Line := GetLineAbs(CurAbs);
        if (Line <> nil) and (FCX < Length(Line)) then
        begin
          Canvas.Font := Font;
          Canvas.Font.Color := FDefaultBG;
          Canvas.Brush.Style := bsClear;
          Canvas.TextOut(R.Left, R.Top, Line[FCX].Ch);
        end;
      end
      else
      begin
        Canvas.Brush.Color := FCursorColor;
        Canvas.FrameRect(R);
      end;
    end;
  end;
end;

procedure TShellTerminal.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1;
end;

procedure TShellTerminal.CMFocusChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate2;
end;

procedure TShellTerminal.Invalidate2;
begin
  FDirty := True;
end;

procedure TShellTerminal.RepaintTick(Sender: TObject);
begin
  if FDirty then
  begin
    FDirty := False;
    UpdateScrollBar;
    inherited Invalidate;
  end;
end;

function TShellTerminal.MaxTopLine: Integer;
begin
  Result := TotalLines - FRows;
  if Result < 0 then Result := 0;
end;

function TShellTerminal.SbTrackRect: TRect;
begin
  Result := Rect(ClientWidth - FSbWidth, 0, ClientWidth, ClientHeight);
end;

function TShellTerminal.SbThumbRect: TRect;
var
  MaxTop, ThumbH, ThumbY, TrackH: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  MaxTop := MaxTopLine;
  if MaxTop <= 0 then Exit;

  TrackH := ClientHeight;
  ThumbH := Round(TrackH * (FRows / TotalLines));
  if ThumbH < 28 then ThumbH := 28;
  if ThumbH > TrackH then ThumbH := TrackH;

  ThumbY := Round((TrackH - ThumbH) * (FTopLine / MaxTop));
  Result := Rect(ClientWidth - FSbWidth + 2, ThumbY, ClientWidth - 2, ThumbY + ThumbH);
end;

procedure TShellTerminal.UpdateScrollBar;
var
  MaxTop: Integer;
begin
  MaxTop := MaxTopLine;
  if FAtBottom then FTopLine := MaxTop;
  if FTopLine > MaxTop then FTopLine := MaxTop;
  if FTopLine < 0 then FTopLine := 0;
end;

procedure TShellTerminal.ScrollToBottom;
begin
  FAtBottom := True;
  FTopLine := TotalLines - FRows;
  if FTopLine < 0 then FTopLine := 0;
  FDirty := True;
end;

// WHEEL-FIX - Resumo breve: so entregamos a roda ao programa quando ele esta na
// tela alternativa (vim, htop). Programas que rodam na tela normal e ligam o
// rastreamento de mouse apenas para clique - o Claude Code entre eles - ignoram
// os botoes 64/65, e mandar a roda para eles fazia o scrollback ficar inerte.
// Fora da tela alternativa o historico e nosso, entao a roda rola o scrollback.
// Shift+roda sempre rola local, igual ao xterm e ao Windows Terminal.
function TShellTerminal.DoMouseWheelUp(Shift: TShiftState; MousePos: TPoint): Boolean;
begin
  Result := True;
  if FUseAlt and (not (ssShift in Shift)) then
  begin
    if FMouseMode <> 0 then
    begin
      MousePos := ScreenToClient(MousePos);
      SendMouse(64, MousePos.X, MousePos.Y, True);
      SendMouse(64, MousePos.X, MousePos.Y, True);
      SendMouse(64, MousePos.X, MousePos.Y, True);
    end
    else if FAppCursorKeys then
      SendStr(ESC + 'OA' + ESC + 'OA' + ESC + 'OA')
    else
      SendStr(ESC + '[A' + ESC + '[A' + ESC + '[A');
    Exit;
  end;
  FTopLine := FTopLine - 3;
  if FTopLine < 0 then FTopLine := 0;
  FAtBottom := False;
  FDirty := True;
end;
// WHEEL-FIX - Final

function TShellTerminal.DoMouseWheelDown(Shift: TShiftState; MousePos: TPoint): Boolean;
var
  MaxTop: Integer;
begin
  Result := True;
  // WHEEL-FIX - ver nota em DoMouseWheelUp
  if FUseAlt and (not (ssShift in Shift)) then
  begin
    if FMouseMode <> 0 then
    begin
      MousePos := ScreenToClient(MousePos);
      SendMouse(65, MousePos.X, MousePos.Y, True);
      SendMouse(65, MousePos.X, MousePos.Y, True);
      SendMouse(65, MousePos.X, MousePos.Y, True);
    end
    else if FAppCursorKeys then
      SendStr(ESC + 'OB' + ESC + 'OB' + ESC + 'OB')
    else
      SendStr(ESC + '[B' + ESC + '[B' + ESC + '[B');
    Exit;
  end;
  MaxTop := TotalLines - FRows;
  if MaxTop < 0 then MaxTop := 0;
  FTopLine := FTopLine + 3;
  if FTopLine >= MaxTop then
  begin
    FTopLine := MaxTop;
    FAtBottom := True;
  end;
  FDirty := True;
end;

// ---------------------------------------------------------------- selecao

function TShellTerminal.PointToCell(X, Y: Integer): TPoint;
begin
  if FCharW = 0 then RecalcMetrics;
  Result.X := X div FCharW;
  Result.Y := FTopLine + (Y div FCharH);
  if Result.X < 0 then Result.X := 0;
  if Result.X > FCols then Result.X := FCols;
end;

procedure TShellTerminal.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: TRect;
begin
  inherited;
  if not Focused then SetFocus;
  // arraste da barra de rolagem
  if (Button = mbLeft) and (X >= ClientWidth - FSbWidth) and (MaxTopLine > 0) then
  begin
    R := SbThumbRect;
    if (Y >= R.Top) and (Y < R.Bottom) then
    begin
      // pegou o polegar: arrasta
      FSbGrabOffset := Y - R.Top;
      FSbDragging := True;
      MouseMove(Shift, X, Y);
    end
    else
    begin
      // SCROLLBAR-FIX - clique na calha rola uma pagina para o lado clicado,
      // como qualquer barra do Windows; antes o polegar saltava para o ponto
      if Y < R.Top then
        ScrollLines(-FRows)
      else
        ScrollLines(FRows);
    end;
    Exit;
  end;

  if Button = mbRight then
  begin
    if FHasSel then
    begin
      CopySelection;
      ClearSelection;
    end
    else
      PasteFromClipboard;
    Exit;
  end;

  if Button = mbLeft then
  begin
    FSelecting := True;
    FSelA := PointToCell(X, Y);
    FSelB := FSelA;
    FHasSel := False;
    FDirty := True;
  end;
end;

procedure TShellTerminal.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  ThumbH, TrackH: Integer;
begin
  inherited;

  if FSbDragging then
  begin
    ThumbH := SbThumbRect.Bottom - SbThumbRect.Top;
    TrackH := ClientHeight - ThumbH;
    if TrackH > 0 then
      FTopLine := Round(MaxTopLine * ((Y - FSbGrabOffset) / TrackH))
    else
      FTopLine := 0;
    if FTopLine < 0 then FTopLine := 0;
    if FTopLine > MaxTopLine then FTopLine := MaxTopLine;
    FAtBottom := FTopLine >= MaxTopLine;
    FDirty := True;
    Exit;
  end;

  if FSelecting then
  begin
    FSelB := PointToCell(X, Y);
    FHasSel := (FSelB.X <> FSelA.X) or (FSelB.Y <> FSelA.Y);
    FDirty := True;
  end;
end;

procedure TShellTerminal.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FSbDragging then
  begin
    FSbDragging := False;
    Exit;
  end;
  if FSelecting then
  begin
    FSelecting := False;
    if FHasSel then CopySelection;
  end;
end;

procedure TShellTerminal.ClearSelection;
begin
  FHasSel := False;
  FDirty := True;
end;

function TShellTerminal.SelectionText: string;
var
  Lo, Hi: TPoint;
  Y, X, X1, X2: Integer;
  Line: TTermLine;
  S: string;
begin
  Result := '';
  if not FHasSel then Exit;
  if (FSelA.Y < FSelB.Y) or ((FSelA.Y = FSelB.Y) and (FSelA.X <= FSelB.X)) then
  begin
    Lo := FSelA; Hi := FSelB;
  end
  else
  begin
    Lo := FSelB; Hi := FSelA;
  end;

  for Y := Lo.Y to Hi.Y do
  begin
    Line := GetLineAbs(Y);
    if Line = nil then Continue;
    if Y = Lo.Y then X1 := Lo.X else X1 := 0;
    if Y = Hi.Y then X2 := Hi.X - 1 else X2 := Length(Line) - 1;
    if X2 > Length(Line) - 1 then X2 := Length(Line) - 1;
    S := '';
    for X := X1 to X2 do
      S := S + Line[X].Ch;
    while (S <> '') and (S[Length(S)] = ' ') do
      SetLength(S, Length(S) - 1);
    if Y < Hi.Y then
      Result := Result + S + sLineBreak
    else
      Result := Result + S;
  end;
end;

procedure TShellTerminal.SelectAll;
begin
  if TotalLines = 0 then Exit;
  FSelA := Point(0, 0);
  FSelB := Point(FCols, TotalLines - 1);
  FHasSel := True;
  FDirty := True;
end;

procedure TShellTerminal.CopySelection;
var
  S: string;
begin
  S := SelectionText;
  if S <> '' then
    Clipboard.AsText := S;
end;

// Grava a imagem do clipboard em arquivo temporario e devolve o caminho.
// E assim que o Claude Code CLI recebe imagem: pelo caminho, nao pelos bytes.
function TShellTerminal.SaveClipboardImage: string;
var
  Bmp: TBitmap;
  Png: TPngImage;
begin
  Result := '';
  if not (Clipboard.HasFormat(CF_BITMAP) or Clipboard.HasFormat(CF_DIB)) then Exit;

  Bmp := TBitmap.Create;
  try
    try
      Bmp.Assign(Clipboard);
    except
      Exit;   // formato que o VCL nao converte
    end;
    if (Bmp.Width = 0) or (Bmp.Height = 0) then Exit;

    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Result := TPath.Combine(TPath.GetTempPath,
        Format('shelldelphi_%s.png', [FormatDateTime('yyyymmdd_hhnnss_zzz', Now)]));
      Png.SaveToFile(Result);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

// Envia caminhos de arquivo como texto, entre aspas quando ha espacos
procedure TShellTerminal.SendPaths(AFiles: TStrings);
var
  I: Integer;
  S, Item: string;
begin
  S := '';
  for I := 0 to AFiles.Count - 1 do
  begin
    Item := AFiles[I];
    if Pos(' ', Item) > 0 then
      Item := '"' + Item + '"';
    if S <> '' then S := S + ' ';
    S := S + Item;
  end;
  if S = '' then Exit;

  if FBracketedPaste then
    SendStr(ESC + '[200~' + S + ESC + '[201~')
  else
    SendStr(S);
  ScrollToBottom;
end;

// Arrastar arquivos para dentro do terminal digita os caminhos
procedure TShellTerminal.WMDropFiles(var Msg: TWMDropFiles);
var
  Count, I, Len: Integer;
  Buf: array[0..MAX_PATH] of Char;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    Count := DragQueryFile(Msg.Drop, $FFFFFFFF, nil, 0);
    for I := 0 to Count - 1 do
    begin
      Len := DragQueryFile(Msg.Drop, I, Buf, Length(Buf));
      if Len > 0 then
        L.Add(Copy(Buf, 1, Len));
    end;
    SendPaths(L);
  finally
    L.Free;
    DragFinish(Msg.Drop);
  end;
  Msg.Result := 0;
  if CanFocus then SetFocus;
end;

procedure TShellTerminal.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TShellTerminal.DestroyWnd;
begin
  if HandleAllocated then
    DragAcceptFiles(Handle, False);
  inherited;
end;

// Le a lista de arquivos do clipboard (CF_HDROP)
function ClipboardFiles(AList: TStrings): Boolean;
var
  H: THandle;
  Count, I, Len: Integer;
  Buf: array[0..MAX_PATH] of Char;
begin
  Result := False;
  if not Clipboard.HasFormat(CF_HDROP) then Exit;
  Clipboard.Open;
  try
    H := GetClipboardData(CF_HDROP);
    if H = 0 then Exit;
    Count := DragQueryFile(H, $FFFFFFFF, nil, 0);
    for I := 0 to Count - 1 do
    begin
      Len := DragQueryFile(H, I, Buf, Length(Buf));
      if Len > 0 then
        AList.Add(Copy(Buf, 1, Len));
    end;
    Result := AList.Count > 0;
  finally
    Clipboard.Close;
  end;
end;

procedure TShellTerminal.PasteFromClipboard;
var
  S: string;
  L: TStringList;
begin
  // 1) arquivos copiados no Explorer
  if Clipboard.HasFormat(CF_HDROP) then
  begin
    L := TStringList.Create;
    try
      if ClipboardFiles(L) then
      begin
        SendPaths(L);
        Exit;
      end;
    finally
      L.Free;
    end;
  end;

  // 2) imagem (print de tela, recorte): vira arquivo e manda o caminho
  if Clipboard.HasFormat(CF_BITMAP) or Clipboard.HasFormat(CF_DIB) then
  begin
    S := SaveClipboardImage;
    if S <> '' then
    begin
      L := TStringList.Create;
      try
        L.Add(S);
        SendPaths(L);
      finally
        L.Free;
      end;
      Exit;
    end;
  end;

  if not (Clipboard.HasFormat(CF_UNICODETEXT) or Clipboard.HasFormat(CF_TEXT)) then Exit;
  S := '';
  try
    S := Clipboard.AsText;
  except
    Exit;   // clipboard travado por outro processo
  end;
  if S = '' then Exit;
  S := StringReplace(S, sLineBreak, #13, [rfReplaceAll]);
  S := StringReplace(S, #10, #13, [rfReplaceAll]);
  if FBracketedPaste then
    SendStr(ESC + '[200~' + S + ESC + '[201~')
  else
    SendStr(S);
  ScrollToBottom;
end;

// ---------------------------------------------------------------- teclado

procedure TShellTerminal.SendStr(const S: string);
begin
  if S <> '' then
    SendBytes(TEncoding.UTF8.GetBytes(S));
end;

// Reporte de mouse para o programa que roda no terminal (Claude Code, vim...).
// ABtn: 0=esq 1=meio 2=dir 64=roda p/ cima 65=roda p/ baixo
procedure TShellTerminal.SendMouse(ABtn, X, Y: Integer; APress: Boolean);
var
  Col, Row: Integer;
  B: TBytes;
begin
  if FCharW = 0 then RecalcMetrics;
  Col := (X div FCharW) + 1;
  Row := (Y div FCharH) + 1;
  if Col < 1 then Col := 1;
  if Row < 1 then Row := 1;

  if FMouseSgr then
  begin
    if APress then
      SendStr(Format('%s[<%d;%d;%dM', [ESC, ABtn, Col, Row]))
    else
      SendStr(Format('%s[<%d;%d;%dm', [ESC, ABtn, Col, Row]));
    Exit;
  end;

  // modo X10/normal: limitado a 223 colunas
  if (Col > 223) or (Row > 223) then Exit;
  SetLength(B, 6);
  B[0] := Ord(ESC);
  B[1] := Ord('[');
  B[2] := Ord('M');
  if APress then
    B[3] := 32 + ABtn
  else
    B[3] := 32 + 3;      // release generico
  B[4] := 32 + Col;
  B[5] := 32 + Row;
  SendBytes(B);
end;

procedure TShellTerminal.SendBytes(const B: TBytes);
begin
  if Assigned(FOnSend) and (Length(B) > 0) then
    FOnSend(Self, B);
end;

// INPUT-FIX - Resumo breve: a IDE do RAD Studio pre-processa as mensagens de
// teclado (ESC fecha a janela dockavel) e o WM_MOUSEWHEEL vai para a janela com
// foco, nao para a que esta sob o cursor. Enquanto o terminal tem o foco, essas
// mensagens pertencem ao processo hospedado, entao as tratamos no filtro da
// aplicacao - o unico ponto anterior ao pre-processamento do VCL e da IDE.
function TShellTerminal.HandleAppMessage(var Msg: TMsg): Boolean;
var
  P: TPoint;
  Delta: Integer;
  Shift: TShiftState;
begin
  Result := False;
  if not HandleAllocated then Exit;

  case Msg.message of
    // WHEEL-FIX - Resumo breve: tratamos a roda aqui mesmo, inclusive quando a
    // mensagem ja esta enderecada a nos. Antes ela era devolvida ao caminho do
    // VCL (WM_MOUSEWHEEL -> MouseWheelHandler -> CM_MOUSEWHEEL -> DoMouseWheel)
    // e dentro da IDE alguma etapa consumia a mensagem antes de chegar la.
    // Chamando DoMouseWheelUp/Down direto, nenhuma etapa intermediaria importa.
    // So a roda vertical: WM_MOUSEHWHEEL ninguem aqui trata, e marcar como
    // tratada fazia a roda horizontal sumir tambem para a IDE.
    WM_MOUSEWHEEL:
      begin
        if not Visible then Exit;
        // COMPAT - lParam e NativeInt: trunca para 32 bits antes de separar
        // X e Y, senao o codigo so funciona em Win32
        P := SmallPointToPoint(TSmallPoint(Cardinal(Msg.lParam)));
        if WindowFromPoint(P) <> Handle then Exit;

        Inc(FDbgWheel);
        Delta := SmallInt(HiWord(Cardinal(Msg.wParam)));
        Shift := KeysToShiftState(LoWord(Cardinal(Msg.wParam)));

        // mesma acumulacao que o TControl.DoMouseWheel faz: rodas de precisao
        // mandam deltas menores que WHEEL_DELTA
        Inc(FWheelAcc, Delta);
        while Abs(FWheelAcc) >= WHEEL_DELTA do
        begin
          Inc(FDbgWheelStep);
          if FWheelAcc < 0 then
          begin
            Inc(FWheelAcc, WHEEL_DELTA);
            DoMouseWheelDown(Shift, P);
          end
          else
          begin
            Dec(FWheelAcc, WHEEL_DELTA);
            DoMouseWheelUp(Shift, P);
          end;
        end;
        Result := True;
      end;

    WM_KEYDOWN, WM_KEYUP, WM_CHAR, WM_DEADCHAR:
      begin
        if (Msg.hwnd <> Handle) or (GetFocus <> Handle) then Exit;
        // combinacoes com Alt continuam indo para a IDE: menus, Alt+F4 e os
        // atalhos do RAD Studio seguem acessiveis
        if GetKeyState(VK_MENU) < 0 then Exit;
        // entrega direto ao controle, sem passar pelo pre-processamento
        TranslateMessage(Msg);
        DispatchMessage(Msg);
        Result := True;
      end;
  end;
end;
// INPUT-FIX - Final

procedure TShellTerminal.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  Msg.Result := DLGC_WANTALLKEYS or DLGC_WANTARROWS or DLGC_WANTCHARS or DLGC_WANTTAB;
end;

// ESC-FIX - Resumo breve: o form dockavel do RAD Studio trata ESC, Tab e
// setas como teclas de dialogo e as consome antes do KeyDown do terminal.
// Enquanto o terminal tem o foco, elas pertencem ao processo hospedado.
procedure TShellTerminal.CMDialogKey(var Msg: TCMDialogKey);
begin
  if Focused then
    case Msg.CharCode of
      VK_ESCAPE, VK_TAB, VK_RETURN,
      VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT:
        begin
          // repassa para o tratamento normal de teclado do terminal
          Perform(WM_KEYDOWN, Msg.CharCode, Msg.KeyData);
          // esta via nao gera WM_CHAR: sem isso o proximo caractere digitado
          // seria descartado pelo KeyPress
          FSuppressNextChar := False;
          Msg.Result := 1;
          Exit;
        end;
    end;
  inherited;
end;

procedure TShellTerminal.CMWantSpecialKey(var Msg: TCMWantSpecialKey);
begin
  case Msg.CharCode of
    VK_ESCAPE, VK_TAB, VK_RETURN,
    VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT:
      Msg.Result := 1;
  else
    inherited;
  end;
end;
// ESC-FIX - Final

procedure TShellTerminal.KeyDown(var Key: Word; Shift: TShiftState);

  function Mods: Integer;
  begin
    Result := 1;
    if ssShift in Shift then Inc(Result, 1);
    if ssAlt in Shift then Inc(Result, 2);
    if ssCtrl in Shift then Inc(Result, 4);
  end;

  procedure CursorKey(Letter: Char);
  var
    M: Integer;
  begin
    M := Mods;
    if M > 1 then
      SendStr(Format('%s[1;%d%s', [ESC, M, Letter]))
    else if FAppCursorKeys then
      SendStr(ESC + 'O' + Letter)
    else
      SendStr(ESC + '[' + Letter);
  end;

  procedure TildeKey(Num: Integer);
  var
    M: Integer;
  begin
    M := Mods;
    if M > 1 then
      SendStr(Format('%s[%d;%d~', [ESC, Num, M]))
    else
      SendStr(Format('%s[%d~', [ESC, Num]));
  end;

var
  Handled: Boolean;
begin
  FSuppressNextChar := False;

  inherited KeyDown(Key, Shift);
  if Key = 0 then Exit;

  // VK_PACKET: caractere injetado por software (remapeadores, teclado virtual,
  // AutoHotkey com SendInput Unicode). Nao tem tecla fisica; deixa o KeyPress
  // entregar o caractere.
  if Key = VK_PACKET then Exit;

  // atalhos do proprio terminal
  if (ssCtrl in Shift) and (ssShift in Shift) then
  begin
    case Key of
      Ord('C'): begin CopySelection; FSuppressNextChar := True; Key := 0; Exit; end;
      Ord('V'): begin PasteFromClipboard; FSuppressNextChar := True; Key := 0; Exit; end;
      Ord('A'): begin SelectAll; FSuppressNextChar := True; Key := 0; Exit; end;
      // DIAG - Ctrl+Shift+D escreve o estado do scroll na propria tela, sem
      // mandar nada para o processo. Serve para diagnosticar a roda do mouse.
      Ord('D'): begin DumpDiag; FSuppressNextChar := True; Key := 0; Exit; end;
      // DIAG - Final
    end;
  end;

  // Ctrl+V cola direto (como Windows Terminal). Ctrl+C copia se houver
  // selecao; sem selecao vai como #3 para interromper o processo.
  if (ssCtrl in Shift) and (not (ssAlt in Shift)) and (not (ssShift in Shift)) then
  begin
    case Key of
      Ord('V'):
        begin
          PasteFromClipboard;
          FSuppressNextChar := True;
          Key := 0;
          Exit;
        end;
      Ord('C'):
        if FHasSel then
        begin
          CopySelection;
          ClearSelection;
          FSuppressNextChar := True;
          Key := 0;
          Exit;
        end;
    end;
  end;
  // SCROLLBAR-FIX - Resumo breve: rolagem do historico pelo teclado, igual ao
  // Windows Terminal. Nao depende da roda do mouse nem da barra, entao funciona
  // mesmo onde o WM_MOUSEWHEEL nao chega ao controle.
  if (ssShift in Shift) and (not (ssCtrl in Shift)) and (not (ssAlt in Shift)) then
    case Key of
      VK_PRIOR: begin ScrollLines(-FRows); Key := 0; Exit; end;   // Shift+PageUp
      VK_NEXT:  begin ScrollLines(FRows);  Key := 0; Exit; end;   // Shift+PageDown
      VK_HOME:  begin FTopLine := 0; FAtBottom := False; FDirty := True;
                      Key := 0; Exit; end;                        // Shift+Home
      VK_END:   begin ScrollToBottom; FDirty := True;
                      Key := 0; Exit; end;                        // Shift+End
      VK_UP:    begin ScrollLines(-1); Key := 0; Exit; end;
      VK_DOWN:  begin ScrollLines(1);  Key := 0; Exit; end;
    end;
  // SCROLLBAR-FIX - Final

  if (Key = VK_INSERT) and (ssShift in Shift) then
  begin
    PasteFromClipboard; Key := 0; Exit;
  end;
  if (Key = VK_INSERT) and (ssCtrl in Shift) then
  begin
    CopySelection; Key := 0; Exit;
  end;

  Handled := True;
  case Key of
    VK_UP:    CursorKey('A');
    VK_DOWN:  CursorKey('B');
    VK_RIGHT: CursorKey('C');
    VK_LEFT:  CursorKey('D');
    VK_HOME:  CursorKey('H');
    VK_END:   CursorKey('F');
    VK_INSERT: TildeKey(2);
    VK_DELETE: TildeKey(3);
    VK_PRIOR:  TildeKey(5);
    VK_NEXT:   TildeKey(6);
    VK_F1: SendStr(ESC + 'OP');
    VK_F2: SendStr(ESC + 'OQ');
    VK_F3: SendStr(ESC + 'OR');
    VK_F4: SendStr(ESC + 'OS');
    VK_F5: TildeKey(15);
    VK_F6: TildeKey(17);
    VK_F7: TildeKey(18);
    VK_F8: TildeKey(19);
    VK_F9: TildeKey(20);
    VK_F10: TildeKey(21);
    VK_F11: TildeKey(23);
    VK_F12: TildeKey(24);
    VK_BACK:
      // Backspace sozinho apaga UM caractere (DEL).
      // Ctrl/Alt + Backspace apagam a palavra inteira (ESC + DEL).
      if (ssCtrl in Shift) or (ssAlt in Shift) then
        SendStr(ESC + #127)
      else
        SendStr(#127);
    VK_TAB:
      if ssShift in Shift then SendStr(ESC + '[Z') else SendStr(#9);
    VK_RETURN:
      if ssShift in Shift then SendStr(ESC + #13) else SendStr(#13);
    VK_ESCAPE: SendStr(ESC);
  else
    Handled := False;
  end;

  if Handled then
  begin
    // Estas teclas ainda geram WM_CHAR depois do KeyDown. Marcamos para o
    // KeyPress descartar, senao a tecla vai duas vezes para o processo.
    case Key of
      VK_BACK, VK_TAB, VK_RETURN, VK_ESCAPE:
        FSuppressNextChar := True;
    end;
    ScrollToBottom;
    ClearSelection;
    Key := 0;
  end;
end;

procedure TShellTerminal.KeyPress(var Key: Char);
var
  B: TBytes;
begin
  inherited KeyPress(Key);
  if Key = #0 then Exit;

  if FSuppressNextChar then
  begin
    FSuppressNextChar := False;
    Key := #0;
    Exit;
  end;

  // Ctrl+letra ja chega como #1..#26 pelo Windows; repassa direto
  B := TEncoding.UTF8.GetBytes(string(Key));
  SendBytes(B);
  ScrollToBottom;
  ClearSelection;
  Key := #0;
end;

// INPUT-FIX - a lista e global; sem isso o pacote vaza ao ser descarregado
initialization

finalization
  // SHUTDOWN-FIX - o pacote pode ser descarregado com o filtro ainda montado
  // (Build/Install repetido, ou fechamento da IDE). Deixar Application.OnMessage
  // apontando para codigo de um BPL ja descarregado derruba a IDE.
  if (Application <> nil) and GHookInstalled and
     (@Application.OnMessage = @TAppMessageHook.AppMessage) then
    Application.OnMessage := GPrevAppMessage;
  GPrevAppMessage := nil;
  GHookInstalled := False;
  FreeAndNil(GTerminals);
// INPUT-FIX - Final

end.
