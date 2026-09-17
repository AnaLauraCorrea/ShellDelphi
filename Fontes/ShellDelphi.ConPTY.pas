unit ShellDelphi.ConPTY;

// ShellDelphi - wrapper da API ConPTY (pseudoconsole nativo do Windows 10 1809+).
// Necessario para rodar TUIs reais (Claude Code, vim, htop) dentro do Delphi.
// Delphi 10.2.3 Tokyo / Win32 / ASCII puro.

interface

uses
  Winapi.Windows, System.Classes, System.SysUtils, System.Win.Registry;

type
  HPCON = THandle;

  TPtyDataEvent = procedure(Sender: TObject; const Data: TBytes) of object;
  TPtyExitEvent = procedure(Sender: TObject; ExitCode: Cardinal) of object;

  TConPty = class;

  TPtyReaderThread = class(TThread)
  private
    FOwner: TConPty;
    procedure PostChunk(AData: TBytes);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TConPty);
  end;

  TConPty = class
  private
    FhPC: HPCON;
    FhPipeIn: THandle;    // nosso lado de escrita (stdin do filho)
    FhPipeOut: THandle;   // nosso lado de leitura (stdout do filho)
    FProcInfo: TProcessInformation;
    FAttrList: Pointer;
    FReader: TPtyReaderThread;
    FRunning: Boolean;
    FPending: Integer;   // blocos na fila da thread principal
    FBytesIn: Int64;     // total lido do pseudoconsole (diagnostico)
    FBytesOut: Int64;    // total entregue ao emulador (diagnostico)
    FCols, FRows: Integer;
    FOnData: TPtyDataEvent;
    FOnExit: TPtyExitEvent;
    procedure CleanupHandles;
    procedure ReaderFinished;
  public
    constructor Create;
    destructor Destroy; override;

    class function Supported: Boolean;

    function Start(const ACommandLine, AWorkDir: string; ACols, ARows: Integer): Boolean;
    procedure Resize(ACols, ARows: Integer);
    procedure Write(const Data: TBytes); overload;
    procedure Write(const S: string); overload;
    procedure Stop;

    property Running: Boolean read FRunning;
    property ProcessId: Cardinal read FProcInfo.dwProcessId;
    property BytesIn: Int64 read FBytesIn;
    property BytesOut: Int64 read FBytesOut;
    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property OnData: TPtyDataEvent read FOnData write FOnData;
    property OnExit: TPtyExitEvent read FOnExit write FOnExit;
  end;

implementation

// Le o PATH direto do registro (maquina + usuario). Necessario porque um
// processo herda o PATH de quem o criou: se a IDE esta aberta desde antes de
// uma ferramenta ser instalada, ela - e todo filho dela - nunca enxerga a
// pasta nova. E exatamente o caso do claude.exe.
function PathAtualDoRegistro: string;

  function LerPath(ARaiz: HKEY; const AChave: string): string;
  var
    Reg: TRegistry;
    Buf: array[0..32767] of Char;
  begin
    Result := '';
    Reg := TRegistry.Create(KEY_READ);
    try
      Reg.RootKey := ARaiz;
      if Reg.OpenKeyReadOnly(AChave) and Reg.ValueExists('Path') then
      begin
        Result := Reg.ReadString('Path');
        // valores REG_EXPAND_SZ trazem %VARIAVEL% sem expandir
        if Pos('%', Result) > 0 then
          if ExpandEnvironmentStrings(PChar(Result), Buf, Length(Buf)) > 0 then
            Result := Buf;
      end;
    except
      // registro inacessivel: segue com o que der
    end;
    Reg.Free;
  end;

var
  Maquina, Usuario: string;
begin
  Maquina := LerPath(HKEY_LOCAL_MACHINE,
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment');
  Usuario := LerPath(HKEY_CURRENT_USER, 'Environment');

  Result := Maquina;
  if (Result <> '') and (Usuario <> '') then
    Result := Result + ';' + Usuario
  else if Result = '' then
    Result := Usuario;
end;

// Monta o bloco de ambiente do filho: o ambiente atual, mas com o PATH
// atualizado. Formato: NOME=VALOR#0NOME=VALOR#0#0
function MontarAmbiente: string;
var
  Env, P: PChar;
  Item, Novo, PathNovo: string;
  TemPath: Boolean;
begin
  Result := '';
  TemPath := False;
  PathNovo := PathAtualDoRegistro;

  Env := GetEnvironmentStrings;
  if Env = nil then Exit;
  try
    P := Env;
    while P^ <> #0 do
    begin
      Item := P;
      // entradas iniciadas por '=' sao internas do Windows; preservar
      if (Item <> '') and (Item[1] <> '=') and
         SameText(Copy(Item, 1, 5), 'PATH=') and (PathNovo <> '') then
      begin
        Novo := 'PATH=' + PathNovo;
        TemPath := True;
      end
      else
        Novo := Item;

      Result := Result + Novo + #0;
      Inc(P, Length(Item) + 1);
    end;
  finally
    FreeEnvironmentStrings(Env);
  end;

  if (not TemPath) and (PathNovo <> '') then
    Result := Result + 'PATH=' + PathNovo + #0;

  Result := Result + #0;
end;

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT_       = $00080000;

type
  TStartupInfoExW_ = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: Pointer;
  end;

  TCreatePseudoConsole = function(size: TCoord; hInput, hOutput: THandle;
    dwFlags: DWORD; var phPC: HPCON): HRESULT; stdcall;
  TResizePseudoConsole = function(hPC: HPCON; size: TCoord): HRESULT; stdcall;
  TClosePseudoConsole  = procedure(hPC: HPCON); stdcall;
  TInitProcThreadAttrList = function(lpAttributeList: Pointer; dwAttributeCount, dwFlags: DWORD;
    var lpSize: SIZE_T): BOOL; stdcall;
  TUpdateProcThreadAttr = function(lpAttributeList: Pointer; dwFlags: DWORD; Attribute: ULONG_PTR;
    lpValue: Pointer; cbSize: SIZE_T; lpPreviousValue: Pointer; lpReturnSize: Pointer): BOOL; stdcall;
  TDeleteProcThreadAttrList = procedure(lpAttributeList: Pointer); stdcall;

var
  _Loaded: Boolean = False;
  _CreatePC: TCreatePseudoConsole = nil;
  _ResizePC: TResizePseudoConsole = nil;
  _ClosePC: TClosePseudoConsole = nil;
  _InitAttr: TInitProcThreadAttrList = nil;
  _UpdAttr: TUpdateProcThreadAttr = nil;
  _DelAttr: TDeleteProcThreadAttrList = nil;

procedure LoadApi;
var
  H: HMODULE;
begin
  if _Loaded then Exit;
  _Loaded := True;
  H := GetModuleHandle('kernel32.dll');
  if H = 0 then Exit;
  @_CreatePC := GetProcAddress(H, 'CreatePseudoConsole');
  @_ResizePC := GetProcAddress(H, 'ResizePseudoConsole');
  @_ClosePC  := GetProcAddress(H, 'ClosePseudoConsole');
  @_InitAttr := GetProcAddress(H, 'InitializeProcThreadAttributeList');
  @_UpdAttr  := GetProcAddress(H, 'UpdateProcThreadAttribute');
  @_DelAttr  := GetProcAddress(H, 'DeleteProcThreadAttributeList');
end;

{ TPtyReaderThread }

constructor TPtyReaderThread.Create(AOwner: TConPty);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

// Entrega um bloco para a thread principal. AData e parametro, entao cada
// chamada captura a SUA copia - com uma variavel local o closure veria o
// valor ja zerado quando finalmente executasse.
procedure TPtyReaderThread.PostChunk(AData: TBytes);
var
  Pty: TConPty;
begin
  Pty := FOwner;
  InterlockedIncrement(Pty.FPending);
  // COMPAT - Queue de instancia (equivale a TThread.Queue(Self, ...)) porque a
  // forma de classe com metodo anonimo nao resolve no Delphi 10.2 Tokyo
  Queue(
    procedure
    begin
      try
        Inc(Pty.FBytesOut, Length(AData));
        if Assigned(Pty.FOnData) then
          Pty.FOnData(Pty, AData);
      finally
        InterlockedDecrement(Pty.FPending);
      end;
    end);
end;

procedure TPtyReaderThread.Execute;
var
  Buf: array[0..8191] of Byte;
  Read: DWORD;
  Chunk: TBytes;
  Pty: TConPty;
begin
  Pty := FOwner;
  while not Terminated do
  begin
    Read := 0;
    if not ReadFile(Pty.FhPipeOut, Buf[0], SizeOf(Buf), Read, nil) then Break;
    if Read = 0 then Break;
    SetLength(Chunk, Read);
    Move(Buf[0], Chunk[0], Read);
    Inc(Pty.FBytesIn, Read);

    // Segura o ritmo se a interface esta atrasada, mas sem BLOQUEAR esperando
    // por ela: Queue mantem a ordem e nunca trava o leitor.
    while (Pty.FPending > 64) and (not Terminated) do
      Sleep(1);

    PostChunk(Chunk);
    Chunk := nil;
  end;
  if not Terminated then
    // Queue ancorado no thread: Stop usa RemoveQueuedEvents e evita
    // executar ReaderFinished depois do TConPty ja ter sido destruido
    // COMPAT - ver nota em PostChunk
    Queue(
      procedure
      begin
        Pty.ReaderFinished;
      end);
end;

{ TConPty }

constructor TConPty.Create;
begin
  inherited Create;
  LoadApi;
  FhPC := 0;
  FhPipeIn := INVALID_HANDLE_VALUE;
  FhPipeOut := INVALID_HANDLE_VALUE;
  FillChar(FProcInfo, SizeOf(FProcInfo), 0);
end;

destructor TConPty.Destroy;
begin
  Stop;
  inherited;
end;

class function TConPty.Supported: Boolean;
begin
  LoadApi;
  Result := Assigned(_CreatePC) and Assigned(_InitAttr) and Assigned(_UpdAttr);
end;

function TConPty.Start(const ACommandLine, AWorkDir: string; ACols, ARows: Integer): Boolean;
var
  Size: TCoord;
  hInRead, hInWrite, hOutRead, hOutWrite: THandle;
  Sa: TSecurityAttributes;
  SiEx: TStartupInfoExW_;
  AttrSize: SIZE_T;
  CmdBuf: array of Char;
  PWorkDir: PChar;
  Hr: HRESULT;
  Ambiente: string;
begin
  Result := False;
  if FRunning then Exit;
  if not Supported then
    raise Exception.Create('ConPTY nao disponivel. Requer Windows 10 1809 ou superior.');

  if ACols < 10 then ACols := 10;
  if ARows < 3 then ARows := 3;
  FCols := ACols;
  FRows := ARows;

  FillChar(Sa, SizeOf(Sa), 0);
  Sa.nLength := SizeOf(Sa);
  Sa.bInheritHandle := False;

  hInRead := 0; hInWrite := 0; hOutRead := 0; hOutWrite := 0;
  if not CreatePipe(hInRead, hInWrite, @Sa, 0) then Exit;
  if not CreatePipe(hOutRead, hOutWrite, @Sa, 0) then
  begin
    CloseHandle(hInRead); CloseHandle(hInWrite);
    Exit;
  end;

  Size.X := ACols;
  Size.Y := ARows;
  Hr := _CreatePC(Size, hInRead, hOutWrite, 0, FhPC);

  // as pontas do filho ja foram duplicadas pelo pseudoconsole
  CloseHandle(hInRead);
  CloseHandle(hOutWrite);

  if Failed(Hr) then
  begin
    CloseHandle(hInWrite); CloseHandle(hOutRead);
    FhPC := 0;
    Exit;
  end;

  FhPipeIn := hInWrite;
  FhPipeOut := hOutRead;

  FillChar(SiEx, SizeOf(SiEx), 0);
  SiEx.StartupInfo.cb := SizeOf(TStartupInfoExW_);
  AttrSize := 0;
  _InitAttr(nil, 1, 0, AttrSize);
  if AttrSize = 0 then
  begin
    CleanupHandles;
    Exit;
  end;
  FAttrList := AllocMem(AttrSize);
  if not _InitAttr(FAttrList, 1, 0, AttrSize) then
  begin
    CleanupHandles;
    Exit;
  end;
  if not _UpdAttr(FAttrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
       Pointer(FhPC), SizeOf(HPCON), nil, nil) then
  begin
    CleanupHandles;
    Exit;
  end;
  SiEx.lpAttributeList := FAttrList;

  // CreateProcessW exige buffer gravavel para a linha de comando
  SetLength(CmdBuf, Length(ACommandLine) + 1);
  if Length(ACommandLine) > 0 then
    Move(PChar(ACommandLine)^, CmdBuf[0], Length(ACommandLine) * SizeOf(Char));
  CmdBuf[Length(ACommandLine)] := #0;

  if AWorkDir <> '' then PWorkDir := PChar(AWorkDir) else PWorkDir := nil;

  // ambiente proprio, com PATH recem-lido do registro
  Ambiente := MontarAmbiente;

  if not CreateProcessW(nil, PWideChar(@CmdBuf[0]), nil, nil, False,
       EXTENDED_STARTUPINFO_PRESENT_ or CREATE_UNICODE_ENVIRONMENT,
       PChar(Ambiente), PWorkDir, PStartupInfoW(@SiEx.StartupInfo)^, FProcInfo) then
  begin
    CleanupHandles;
    Exit;
  end;

  FRunning := True;
  FReader := TPtyReaderThread.Create(Self);
  Result := True;
end;

procedure TConPty.Resize(ACols, ARows: Integer);
var
  Size: TCoord;
begin
  if (FhPC = 0) or not Assigned(_ResizePC) then Exit;
  if ACols < 10 then ACols := 10;
  if ARows < 3 then ARows := 3;
  if (ACols = FCols) and (ARows = FRows) then Exit;
  FCols := ACols;
  FRows := ARows;
  Size.X := ACols;
  Size.Y := ARows;
  _ResizePC(FhPC, Size);
end;

procedure TConPty.Write(const Data: TBytes);
var
  Written: DWORD;
begin
  if (not FRunning) or (Length(Data) = 0) then Exit;
  if FhPipeIn = INVALID_HANDLE_VALUE then Exit;
  WriteFile(FhPipeIn, Data[0], Length(Data), Written, nil);
end;

procedure TConPty.Write(const S: string);
begin
  if S <> '' then
    Write(TEncoding.UTF8.GetBytes(S));
end;

procedure TConPty.ReaderFinished;
var
  Code: Cardinal;
begin
  if not FRunning then Exit;
  FRunning := False;
  Code := 0;
  if FProcInfo.hProcess <> 0 then
  begin
    WaitForSingleObject(FProcInfo.hProcess, 3000);
    GetExitCodeProcess(FProcInfo.hProcess, Code);
  end;
  if Assigned(FOnExit) then FOnExit(Self, Code);
end;

procedure TConPty.CleanupHandles;
begin
  if Assigned(FAttrList) then
  begin
    if Assigned(_DelAttr) then _DelAttr(FAttrList);
    FreeMem(FAttrList);
    FAttrList := nil;
  end;
  if FhPC <> 0 then
  begin
    if Assigned(_ClosePC) then _ClosePC(FhPC);
    FhPC := 0;
  end;
  if FhPipeIn <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FhPipeIn);
    FhPipeIn := INVALID_HANDLE_VALUE;
  end;
  if FhPipeOut <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FhPipeOut);
    FhPipeOut := INVALID_HANDLE_VALUE;
  end;
end;

procedure TConPty.Stop;
begin
  FOnData := nil;
  FOnExit := nil;
  FRunning := False;

  if Assigned(FReader) then
    FReader.Terminate;

  // ClosePseudoConsole encerra o filho e libera o ReadFile pendente do leitor
  if FhPC <> 0 then
  begin
    if Assigned(_ClosePC) then _ClosePC(FhPC);
    FhPC := 0;
  end;

  if FProcInfo.hProcess <> 0 then
  begin
    if WaitForSingleObject(FProcInfo.hProcess, 2000) = WAIT_TIMEOUT then
      TerminateProcess(FProcInfo.hProcess, 0);
  end;

  if Assigned(FReader) then
  begin
    if FhPipeOut <> INVALID_HANDLE_VALUE then
      CancelIoEx(FhPipeOut, nil);

    // O leitor so le do pipe ou dorme; nunca espera a thread principal.
    // Com o pseudoconsole fechado e o I/O cancelado, ele sai sozinho.
    FReader.WaitFor;

    // Depois do WaitFor nada mais e enfileirado: descarta o que sobrou para
    // nenhum closure tocar neste TConPty depois que ele for destruido.
    TThread.RemoveQueuedEvents(FReader);
    FreeAndNil(FReader);
    FPending := 0;
  end;

  CleanupHandles;

  if FProcInfo.hThread <> 0 then
  begin
    CloseHandle(FProcInfo.hThread);
    FProcInfo.hThread := 0;
  end;
  if FProcInfo.hProcess <> 0 then
  begin
    CloseHandle(FProcInfo.hProcess);
    FProcInfo.hProcess := 0;
  end;
end;

end.
