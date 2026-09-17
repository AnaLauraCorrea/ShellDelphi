program ShellDelphiHost;

// ShellDelphi - host autonomo.
// Roda em processo proprio: continua 100% responsivo enquanto o RAD Studio
// compila, enquanto o SACWIN faz carga pesada, ou enquanto qualquer outro
// processo trava sua propria thread principal.
//
// Uso:
//   ShellDelphiHost.exe                 -> abre 1 aba PowerShell
//   ShellDelphiHost.exe C:\Sacwin...    -> abre 1 aba nesse diretorio
//   ShellDelphiHost.exe C:\Sacwin... /claude -> ja abre rodando Claude Code

uses
  Vcl.Forms,
  Winapi.Windows,
  System.SysUtils,
  Vcl.Controls,
  Vcl.Graphics,
  System.Classes,
  ShellDelphi.ConPTY in '..\Fontes\ShellDelphi.ConPTY.pas',
  ShellDelphi.Terminal in '..\Fontes\ShellDelphi.Terminal.pas',
  ShellDelphi in '..\Fontes\ShellDelphi.pas';

// Sem {$R *.res} de proposito: permite compilar direto por dcc32 sem .res gerado.

var
  Form: TForm;
  Shell: TShellDelphi;
  Dir: string;
  UseClaude: Boolean;
  I: Integer;
begin
  Application.Initialize;
  Application.Title := 'ShellDelphi';
  Application.MainFormOnTaskbar := True;

  Dir := '';
  UseClaude := False;
  for I := 1 to ParamCount do
  begin
    if SameText(ParamStr(I), '/claude') then
      UseClaude := True
    else if Dir = '' then
      Dir := ParamStr(I);
  end;
  if Dir = '' then Dir := GetCurrentDir;

  Application.CreateForm(TForm, Form);
  Form.Caption := 'ShellDelphi - ' + Dir;
  Form.Width := 1100;
  Form.Height := 680;
  Form.Position := poScreenCenter;
  Form.Color := $001E1E1E;

  Shell := TShellDelphi.Create(Form);
  Shell.Parent := Form;
  Shell.Align := alClient;
  Shell.WorkDir := Dir;

  Form.Show;

  try
    if UseClaude then
      Shell.NewClaudeTab(Dir)
    else
      Shell.NewTab('', '', Dir);
  except
    on E: Exception do
      MessageBox(Form.Handle, PChar(E.Message), 'ShellDelphi', MB_ICONERROR or MB_OK);
  end;

  Application.Run;
end.
