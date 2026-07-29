; Oriel's wizard (oriel-distribution ticket 08).
;
; It owns none of the judgement. Triage, the consent text, patching, refusal,
; verification and uninstall all come from src/install/Install-Oriel.ps1 — there is one
; implementation of the risky half and two front ends over it (ADR 0012). What this
; file contributes is twenty-year-old solved Windows plumbing: a directory page, a
; Start Menu shortcut, an Add/Remove Programs entry, and an uninstaller.
;
; This is also the part of the feature that is NOT automatically tested, stated plainly
; rather than papered over: the wizard pages, the shortcut, the ARP entry and the
; elevation-free install are verified by hand once per release — see RELEASE.md. The
; design keeps this region thin on purpose. Anything that touches the user's
; configuration belongs behind the entry point, not here.
;
; Build:  iscc installer\Oriel.iss
; Expects dist\Oriel.exe to exist (pwsh -NoProfile -File build.ps1).

#define AppName        "Oriel"
#define AppPublisher   "Oriel"
#define AppUrl         "https://github.com/bolduck91/oriel"
#define AppExeName     "Oriel.exe"
#define SourceRoot     ".."

; Read the version from the one place it is written, so an installer can never
; advertise a version the binary is not.
#define AppVersion GetVersionNumbersString(SourceRoot + "\dist\Oriel.exe")

[Setup]
AppId={{8D5C3C51-6F1E-4C2E-9E0D-2A2F0B7A1E64}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
DefaultDirName={localappdata}\Programs\Oriel
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#SourceRoot}\dist
OutputBaseFilename=OrielSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

; Per-user, and therefore no UAC shield at any point. The shield is the screen that
; stops exactly the person this installer exists to serve (ADR 0012), so this is not a
; convenience — it is the requirement.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

Uninstallable=yes
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceRoot}\dist\{#AppExeName}";        DestDir: "{app}";           Flags: ignoreversion
Source: "{#SourceRoot}\src\install\*.ps1";         DestDir: "{app}\install";   Flags: ignoreversion
Source: "{#SourceRoot}\src\tee\*.ps1";             DestDir: "{app}\tee";       Flags: ignoreversion
Source: "{#SourceRoot}\LICENSE";                   DestDir: "{app}";           Flags: ignoreversion
Source: "{#SourceRoot}\README.md";                 DestDir: "{app}";           Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"

[Run]
; The finish page's offer. nowait so the wizard closes rather than sitting behind the
; widget it just launched.
Filename: "{app}\{#AppExeName}"; Description: "Launch Oriel now"; Flags: nowait postinstall skipifsilent

[Code]
var
  ConsentPage: TOutputMsgMemoWizardPage;
  TriageVerdict: String;
  TriageMessage: String;
  TriageBlock: String;
  ConversionPrompt: String;
  InstallFailure: String;

{ ---- driving the entry point ------------------------------------------------ }

function CmdLineParamExists(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

{ /SKIPCONFIG installs Oriel's own files and stops there, touching nothing of the
  user's. It exists for the one-line terminal install (ticket 09), which needs the real
  entry point on disk in order to show the consent text before anything is changed —
  and which then either runs the install action or rolls the whole thing back. It is
  not a supported way to install by hand: it leaves a widget with no tee. }
function ConfigStepSkipped(): Boolean;
begin
  Result := CmdLineParamExists('/SKIPCONFIG');
end;

function PowerShellExe(): String;
begin
  { pwsh when the machine has it, Windows PowerShell otherwise. The entry point runs
    on 5.1 by design (ADR 0013), so the fallback is a floor and not a compromise. }
  Result := ExpandConstant('{localappdata}\Microsoft\WindowsApps\pwsh.exe');
  if not FileExists(Result) then
    Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function RunEntryPoint(const Action: String; const ExtraArgs: String; var Output: String): Integer;
var
  ReportPath, Args: String;
  ResultCode: Integer;
  Lines: TArrayOfString;
  I: Integer;
begin
  ReportPath := ExpandConstant('{tmp}\oriel-report.json');
  DeleteFile(ReportPath);

  { -Json makes the entry point emit one machine-readable object; redirecting it to a
    file rather than parsing a console is the only reliable way to read it from here. }
  Args := '-NoProfile -ExecutionPolicy Bypass -Command "& ''' +
          ExpandConstant('{app}\install\Install-Oriel.ps1') + ''' -Action ' + Action +
          ' -TeePath ''' + ExpandConstant('{app}\tee\Write-UsageState.ps1') + '''' +
          ' -Json ' + ExtraArgs + ' | Set-Content -LiteralPath ''' + ReportPath + ''' -Encoding utf8"';

  if not Exec(PowerShellExe(), Args, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Output := '';
    Result := -1;
    Exit;
  end;

  Output := '';
  if LoadStringsFromFile(ReportPath, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      Output := Output + Lines[I] + #13#10;

  Result := ResultCode;
end;

{ A deliberately small reader rather than a JSON parser: the report's shape is ours,
  and Inno's Pascal has no JSON library worth pulling in for five fields. }
function JsonString(const Body, Key: String): String;
var
  Marker: String;
  P, Q: Integer;
  Ch: Char;
begin
  Result := '';
  Marker := '"' + Key + '":';
  P := Pos(Marker, Body);
  if P = 0 then Exit;
  P := P + Length(Marker);
  while (P <= Length(Body)) and (Body[P] = ' ') do P := P + 1;
  if (P > Length(Body)) or (Body[P] <> '"') then Exit;
  P := P + 1;
  Q := P;
  while Q <= Length(Body) do
  begin
    Ch := Body[Q];
    if Ch = '\' then
    begin
      { The report carries Windows paths and multi-line prose, so escapes have to be
        undone or the consent page shows \r\n and \\ to the user. }
      if Q + 1 <= Length(Body) then
      begin
        case Body[Q + 1] of
          'n': Result := Result + #10;
          'r': Result := Result + #13;
          't': Result := Result + #9;
          '\': Result := Result + '\';
          '"': Result := Result + '"';
          '/': Result := Result + '/';
        else
          Result := Result + Body[Q + 1];
        end;
      end;
      Q := Q + 2;
    end
    else if Ch = '"' then
      Break
    else
    begin
      Result := Result + Ch;
      Q := Q + 1;
    end;
  end;
end;

{ ---- the consent page ------------------------------------------------------- }

procedure InitializeWizard();
begin
  ConsentPage := CreateOutputMsgMemoPage(wpSelectDir,
    'Your statusline',
    'What Oriel will change, before it changes it',
    'Oriel reads the data Claude Code already pushes to your statusline. To do that it ' +
    'adds a small block to your statusline script. Read it below. If you continue, this ' +
    'is exactly what will be added — nothing else in your file is touched. If you go ' +
    'Back or Cancel, nothing is changed at all.',
    'Reading your Claude Code settings...');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Body: String;
  Code: Integer;
begin
  if CurPageID = ConsentPage.ID then
  begin
    { The wizard's own consent page. The terminal front end never reaches it — it runs
      silently and takes the same consent in the console (ADR 0012). }
    { Triage runs here rather than at install time so the user sees the verdict BEFORE
      committing to anything. It writes nothing. }
    Code := RunEntryPoint('triage', '', Body);
    TriageVerdict := JsonString(Body, 'verdict');
    TriageMessage := JsonString(Body, 'message');
    TriageBlock := JsonString(Body, 'block');
    ConversionPrompt := JsonString(Body, 'conversionPrompt');

    if Code = 2 then
    begin
      { A refusal is surfaced as a refusal, never swallowed into a green checkmark. }
      ConsentPage.RichEditViewer.Text :=
        'Oriel cannot install into your statusline.' + #13#10#13#10 +
        TriageMessage + #13#10#13#10 +
        'Nothing on your disk has been changed, and nothing will be.' + #13#10#13#10 +
        'Copy the text below, paste it into Claude Code to convert your statusline, ' +
        'then run this installer again:' + #13#10#13#10 +
        ConversionPrompt;
    end
    else if Code <> 0 then
    begin
      ConsentPage.RichEditViewer.Text :=
        'Oriel could not read your Claude Code settings.' + #13#10#13#10 +
        'You can continue — the installer will try again and will tell you plainly if it ' +
        'cannot finish. Nothing is changed until then.';
    end
    else
    begin
      ConsentPage.RichEditViewer.Text :=
        TriageMessage + #13#10#13#10 +
        'The exact text that will be added:' + #13#10#13#10 +
        TriageBlock + #13#10#13#10 +
        'Oriel also checks once at startup whether a newer version exists. It downloads ' +
        'nothing, and you can switch the check off from the widget''s right-click menu.';
    end;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = ConsentPage.ID) and (TriageVerdict = 'refuse') then
  begin
    { Declining is not a failure state to be argued with, but continuing past a refusal
      would install a widget that shows dashes forever — the exact trap this feature
      exists to remove. }
    MsgBox('Oriel cannot serve your current statusline, so there is nothing to install. ' +
           'Convert your statusline with the text on the previous page and run this ' +
           'installer again.', mbInformation, MB_OK);
    Result := False;
  end;
end;

{ ---- install and uninstall -------------------------------------------------- }

procedure CurStepChanged(CurStep: TSetupStep);
var
  Body: String;
  Code: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    { The files are on disk; now the part that touches the user's configuration. }
    if ConfigStepSkipped() then Exit;

    Code := RunEntryPoint('install', '', Body);
    if Code = 0 then
      InstallFailure := ''
    else
      InstallFailure := JsonString(Body, 'message');

    if Code = 2 then
      { Note: a line whose first non-blank character is # is read by the preprocessor
        as a directive, so a wrapped string must never begin with #13#10. Keep the
        newline literals at the END of a line, behind the concatenation operator. }
      MsgBox('Oriel could not install into your statusline, and nothing was changed:' + #13#10#13#10 +
             InstallFailure, mbError, MB_OK)
    else if Code = 3 then
      { Success is only shown after verification passed. This one is the whole reason
        verification exists: the managed block is fail-silent, so without this the user
        would find out days later, from a widget showing dashes. }
      MsgBox('Oriel was installed, but it could not confirm that data started flowing, ' +
             'so this is not being reported as a success:' + #13#10#13#10 + InstallFailure,
             mbError, MB_OK)
    else if Code <> 0 then
      MsgBox('Oriel could not finish setting up your statusline:' + #13#10#13#10 +
             InstallFailure, mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Args: String;
  ResultCode: Integer;
  Keep: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    { A user who was given a starter statusline is asked whether to keep it — it may be
      something they have come to rely on, and it is theirs. }
    Keep := '';
    if MsgBox('Keep the statusline Oriel wrote for you (if it wrote one)?' + #13#10#13#10 +
              'Yes: it stays, working, with Oriel''s block removed.' + #13#10 +
              'No: it is removed and your Claude Code settings go back to how they were.',
              mbConfirmation, MB_YESNO) = IDYES then
      Keep := ' -KeepStarter';

    Args := '-NoProfile -ExecutionPolicy Bypass -File "' +
            ExpandConstant('{app}\install\Install-Oriel.ps1') + '" -Action uninstall' + Keep;
    Exec(PowerShellExe(), Args, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
