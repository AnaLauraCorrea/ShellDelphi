unit ShellDelphi.IDE;

// ShellDelphi - integracao com o RAD Studio via ToolsAPI.
// Registra uma janela DOCKAVEL (INTACustomDockableForm), igual Object Inspector /
// Structure / Project Manager: pode encaixar em qualquer borda da IDE, virar aba,
// flutuar, e o estado e salvo no Desktop do RAD Studio.
//
// Menu: View > ShellDelphi Terminal
//
// Delphi 10.2.3 Tokyo / Win32 / ASCII puro.

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IniFiles,
  Vcl.Forms, Vcl.Controls, Vcl.Menus, Vcl.ActnList, Vcl.ImgList, Vcl.ComCtrls,
  Vcl.Graphics, System.StrUtils, DesignIntf, ToolsAPI, ShellDelphi, ShellDelphi.ConPTY, ShellDelphi.Terminal;

{$R *.dfm}

const
  cFormIdent  = 'ShellDelphiTerminal';
  cFormCap    = 'ShellDelphi Terminal';
  cMenuIdent  = 'ShellDelphiViewMenuItem';

type
  // Frame hospedado pela janela dockavel da IDE
  TShellDelphiFrame = class(TCustomFrame)
  private
    FShell: TShellDelphi;
    procedure ShellExit(Sender: TObject; Session: TShellSession; ExitCode: Cardinal);
    procedure ShellGetWorkDir(Sender: TObject; var ADir: string);
  public
    constructor Create(AOwner: TComponent); override;
    property Shell: TShellDelphi read FShell;
  end;

  TShellDockableForm = class(TInterfacedObject, INTACustomDockableForm)
  private
    FFrame: TShellDelphiFrame;
  public
    // INTACustomDockableForm
    function GetCaption: string;
    function GetIdentifier: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    function GetMenuActionList: TCustomActionList;
    function GetMenuImageList: TCustomImageList;
    procedure CustomizePopupMenu(PopupMenu: TPopupMenu);
    function GetToolBarActionList: TCustomActionList;
    function GetToolBarImageList: TCustomImageList;
    procedure CustomizeToolBar(ToolBar: TToolBar);
    procedure SaveWindowState(Desktop: TCustomIniFile; const Section: string; IsProject: Boolean);
    procedure LoadWindowState(Desktop: TCustomIniFile; const Section: string);
    function GetEditState: TEditState;
    function EditAction(Action: TEditAction): Boolean;
    function ActiveTerminal: TShellTerminal;

    property Frame: TShellDelphiFrame read FFrame;
  end;

var
  GDockable: INTACustomDockableForm = nil;
  GForm: TCustomForm = nil;
  GMenuItem: TMenuItem = nil;

{ ------------------------------------------------------------------ helpers }

// Diretorio do projeto ativo no RAD Studio; usado como pasta inicial do shell
function ActiveProjectDir: string;
var
  MS: IOTAModuleServices;
  I: Integer;
  M: IOTAModule;
  PG: IOTAProjectGroup;
  Prj: IOTAProject;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAModuleServices, MS) then Exit;

  // 1) projeto ativo do grupo de projetos
  Prj := nil;
  for I := 0 to MS.ModuleCount - 1 do
    if Supports(MS.Modules[I], IOTAProjectGroup, PG) then
    begin
      Prj := PG.ActiveProject;
      Break;
    end;

  // 2) sem grupo: primeiro projeto aberto
  if Prj = nil then
    for I := 0 to MS.ModuleCount - 1 do
      if Supports(MS.Modules[I], IOTAProject, Prj) then
        Break;

  if Assigned(Prj) then
    Result := ExtractFilePath(Prj.FileName);

  // 3) ultimo recurso: pasta do arquivo aberto no editor. GetCurrentDir NAO
  //    serve - e a pasta do ultimo projeto que a IDE abriu, nao a do atual.
  if Result = '' then
  begin
    M := MS.CurrentModule;
    if Assigned(M) and (M.FileName <> '') then
      Result := ExtractFilePath(M.FileName);
  end;

  if Result = '' then
    Result := GetCurrentDir;
end;

{ ------------------------------------------------------------- TShellDelphiFrame }

constructor TShellDelphiFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := cFormCap;

  FShell := TShellDelphi.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.WorkDir := ActiveProjectDir;
  FShell.KeepAliveOnExit := True;   // na IDE, manter a aba mostrando o encerramento
  FShell.OnShellExit := ShellExit;
  // consultado a cada aba nova: sempre o projeto ativo do momento
  FShell.OnGetWorkDir := ShellGetWorkDir;
end;

procedure TShellDelphiFrame.ShellExit(Sender: TObject; Session: TShellSession;
  ExitCode: Cardinal);
begin
  // aba permanece visivel com o status; usuario fecha manualmente
end;

procedure TShellDelphiFrame.ShellGetWorkDir(Sender: TObject; var ADir: string);
begin
  ADir := ActiveProjectDir;
end;

{ ------------------------------------------------------------ TShellDockableForm }

function TShellDockableForm.GetCaption: string;
begin
  Result := cFormCap;
end;

function TShellDockableForm.GetIdentifier: string;
begin
  Result := cFormIdent;
end;

function TShellDockableForm.GetFrameClass: TCustomFrameClass;
begin
  Result := TShellDelphiFrame;
end;

procedure TShellDockableForm.FrameCreated(AFrame: TCustomFrame);
begin
  FFrame := AFrame as TShellDelphiFrame;
end;

function TShellDockableForm.GetMenuActionList: TCustomActionList;
begin
  Result := nil;
end;

function TShellDockableForm.GetMenuImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TShellDockableForm.CustomizePopupMenu(PopupMenu: TPopupMenu);
begin
  // nada extra: a barra do proprio TShellDelphi ja expoe as acoes
end;

function TShellDockableForm.GetToolBarActionList: TCustomActionList;
begin
  Result := nil;
end;

function TShellDockableForm.GetToolBarImageList: TCustomImageList;
begin
  Result := nil;
end;

procedure TShellDockableForm.CustomizeToolBar(ToolBar: TToolBar);
begin
end;

procedure TShellDockableForm.SaveWindowState(Desktop: TCustomIniFile;
  const Section: string; IsProject: Boolean);
begin
  if Assigned(FFrame) and Assigned(FFrame.Shell) then
    Desktop.WriteString(Section, 'WorkDir', FFrame.Shell.WorkDir);
end;

procedure TShellDockableForm.LoadWindowState(Desktop: TCustomIniFile;
  const Section: string);
var
  Dir: string;
begin
  if Assigned(FFrame) and Assigned(FFrame.Shell) then
  begin
    Dir := Desktop.ReadString(Section, 'WorkDir', '');
    if (Dir <> '') and DirectoryExists(Dir) then
      FFrame.Shell.WorkDir := Dir;
  end;
end;

// Terminal da aba ativa, ou nil
function TShellDockableForm.ActiveTerminal: TShellTerminal;
var
  Sess: TShellSession;
begin
  Result := nil;
  if not Assigned(FFrame) then Exit;
  if not Assigned(FFrame.Shell) then Exit;
  Sess := FFrame.Shell.ActiveSession;
  if Assigned(Sess) then
    Result := Sess.Terminal;
end;

function TShellDockableForm.GetEditState: TEditState;
begin
  // Habilita os itens do menu Edit da IDE enquanto o terminal esta ativo.
  if ActiveTerminal <> nil then
    Result := [esCanCopy, esCanPaste, esCanSelectAll]
  else
    Result := [];
end;

function TShellDockableForm.EditAction(Action: TEditAction): Boolean;
var
  T: TShellTerminal;
begin
  Result := False;
  T := ActiveTerminal;
  if T = nil then Exit;

  case Action of
    eaCopy:      begin T.CopySelection; Result := True; end;
    eaCut:       begin T.CopySelection; Result := True; end;
    eaPaste:     begin T.PasteFromClipboard; Result := True; end;
    eaSelectAll: begin T.SelectAll; Result := True; end;
  end;
end;

{ ------------------------------------------------------------------- docking }

// A IDE do RAD Studio expoe os locais de encaixe como controles chamados
// DockSite0..DockSite4 no formulario principal (AppBuilder). Em vez de chutar
// qual e qual, procuramos pelo Align - assim funciona em qualquer layout.
function FindIdeDockSite(AAlign: TAlign): TWinControl;
var
  MF: TCustomForm;
  I: Integer;
  C: TComponent;
  WC: TWinControl;
begin
  Result := nil;
  MF := Application.MainForm;
  if MF = nil then Exit;

  for I := 0 to MF.ComponentCount - 1 do
  begin
    C := MF.Components[I];
    if not (C is TWinControl) then Continue;
    if not StartsText('DockSite', C.Name) then Continue;

    WC := TWinControl(C);
    if WC.DockSite and (WC.Align = AAlign) then
      Exit(WC);
  end;
end;

// Encaixa a janela na parte de baixo da IDE na primeira vez que ela abre.
// Se a IDE ja tiver posicao salva no Desktop, nao mexemos em nada.
procedure DockToIde(AForm: TCustomForm);
var
  Site: TWinControl;
begin
  if AForm = nil then Exit;
  if AForm.HostDockSite <> nil then Exit;   // ja esta encaixada

  Site := FindIdeDockSite(alBottom);
  if Site = nil then
    Site := FindIdeDockSite(alRight);
  if Site = nil then Exit;                  // layout inesperado: deixa flutuando

  try
    AForm.ManualDock(Site, nil, alBottom);
  except
    // docking e best-effort; falhando, a janela continua flutuante e usavel
  end;
end;

{ ------------------------------------------------------------------ show/hide }

procedure ShowShellDelphiWindow;
var
  NTA: INTAServices;
  Frame: TShellDelphiFrame;
  FirstTime: Boolean;
begin
  if not Supports(BorlandIDEServices, INTAServices, NTA) then Exit;

  FirstTime := GForm = nil;
  if FirstTime then
    GForm := NTA.CreateDockableForm(GDockable);

  if GForm <> nil then
  begin
    if FirstTime then
      DockToIde(GForm);

    GForm.Show;
    GForm.BringToFront;
    if GForm.CanFocus then GForm.SetFocus;

    // primeira abertura: ja sobe uma aba de PowerShell no projeto ativo
    Frame := (GDockable as TShellDockableForm).Frame;
    if Assigned(Frame) and Assigned(Frame.Shell) and (Frame.Shell.SessionCount = 0) then
    begin
      Frame.Shell.WorkDir := ActiveProjectDir;
      try
        Frame.Shell.NewTab('', '', Frame.Shell.WorkDir);
      except
        on E: Exception do
          MessageBox(0, PChar(E.Message), 'ShellDelphi', MB_ICONERROR or MB_OK);
      end;
    end;
  end;
end;

// Avisa quando a IDE troca de projeto ativo, para as proximas abas nascerem
// na pasta certa mesmo com a janela ja aberta ha tempo.
type
  TProjetoNotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

procedure TProjetoNotifier.FileNotification(NotifyCode: TOTAFileNotification;
  const FileName: string; var Cancel: Boolean);
var
  Frame: TShellDelphiFrame;
begin
  if NotifyCode <> ofnActiveProjectChanged then Exit;
  if GDockable = nil then Exit;

  Frame := (GDockable as TShellDockableForm).Frame;
  if Assigned(Frame) and Assigned(Frame.Shell) then
    Frame.Shell.WorkDir := ActiveProjectDir;
end;

procedure TProjetoNotifier.BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
begin
end;

procedure TProjetoNotifier.AfterCompile(Succeeded: Boolean);
begin
end;

type
  TMenuHandler = class
    procedure ShowClick(Sender: TObject);
  end;

var
  GHandler: TMenuHandler = nil;
  GNotifierIdx: Integer = -1;

procedure TMenuHandler.ShowClick(Sender: TObject);
begin
  ShowShellDelphiWindow;
end;

procedure AddViewMenuItem;
var
  NTA: INTAServices;
  ViewMenu: TMenuItem;
  I: Integer;
begin
  if not Supports(BorlandIDEServices, INTAServices, NTA) then Exit;
  if NTA.MainMenu = nil then Exit;

  ViewMenu := nil;
  for I := 0 to NTA.MainMenu.Items.Count - 1 do
    if SameText(NTA.MainMenu.Items[I].Name, 'ViewsMenu') then
    begin
      ViewMenu := NTA.MainMenu.Items[I];
      Break;
    end;
  if ViewMenu = nil then Exit;

  GHandler := TMenuHandler.Create;

  GMenuItem := TMenuItem.Create(nil);
  GMenuItem.Name := cMenuIdent;
  GMenuItem.Caption := cFormCap;
  GMenuItem.OnClick := GHandler.ShowClick;
  ViewMenu.Insert(0, GMenuItem);
end;

procedure RemoveViewMenuItem;
begin
  FreeAndNil(GMenuItem);
  FreeAndNil(GHandler);
end;

procedure Register;
var
  NTA: INTAServices;
  Svc: IOTAServices;
begin
  if not TConPty.Supported then
  begin
    MessageBox(0, 'ShellDelphi: ConPTY indisponivel (requer Windows 10 1809+). '
      + 'A janela nao sera registrada.', 'ShellDelphi', MB_ICONWARNING or MB_OK);
    Exit;
  end;

  GDockable := TShellDockableForm.Create;
  if Supports(BorlandIDEServices, INTAServices, NTA) then
    NTA.RegisterDockableForm(GDockable);

  if Supports(BorlandIDEServices, IOTAServices, Svc) then
    GNotifierIdx := Svc.AddNotifier(TProjetoNotifier.Create);

  AddViewMenuItem;
end;

initialization

finalization
  // SHUTDOWN-FIX - remover o notifier pode falhar se a IDE ja desmontou o
  // servico; deixar escapar daqui vira Access Violation sem origem aparente
  if GNotifierIdx >= 0 then
  begin
    try
      if Supports(BorlandIDEServices, IOTAServices) then
        (BorlandIDEServices as IOTAServices).RemoveNotifier(GNotifierIdx);
    except
      // nada a fazer: estamos encerrando
    end;
    GNotifierIdx := -1;
  end;
  RemoveViewMenuItem;
  if Assigned(GDockable) then
  begin
    if Assigned(GForm) then
    begin
      // SHUTDOWN-FIX - Resumo breve: aqui tem que ser Free, nunca Release.
      // O Release apenas POSTA uma mensagem para o form se destruir no proximo
      // ciclo - mas estamos na finalization do pacote, e o .bpl sai da memoria
      // antes disso. Quando a VCL processava a mensagem, o codigo do form ja
      // nao existia: Access Violation dentro do vcl<versao>.bpl ao fechar a IDE.
      try
        FreeAndNil(GForm);
      except
        GForm := nil;
      end;
    end;

    if Supports(BorlandIDEServices, INTAServices) then
      try
        (BorlandIDEServices as INTAServices).UnregisterDockableForm(GDockable);
      except
        // a IDE pode ja ter derrubado o servico; nao ha o que fazer
      end;
    GDockable := nil;
  end;

end.
