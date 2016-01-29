unit AES;

{$IFOPT Q+}
  {$DEFINE OverflowCheck}
{$ENDIF}

interface

uses
  Classes,
  AuxTypes;

type
  TBCMode            = (cmUndefined,cmEncrypt,cmDecrypt);
  TBCModeOfOperation = (moECB,moCBC,moPCBC,moCFB,moOFB,moCTR);
  TBCPadding         = (padZeroes,padPKCS7);

  TBCUpdateProc = procedure(const Input; out Output) of object;
  TProgressEvent = procedure(Sender: TObject; Progress: Single) of object;

  TBlockCipher = class(TObject)
  private
    fMode:            TBCMode;
    fModeOfOperation: TBCModeOfOperation;
    fPadding:         TBCPadding;
    fInitVector:      Pointer;
    fInitVectorBytes: TMemSize;
    fKey:             Pointer;
    fKeyBytes:        TMemSize;
    fTempBlock:       Pointer;
    fBlockBytes:      TMemSize;
    fUpdateProc:      TBCUpdateProc;
    fOnProgress:      TProgressEvent;
    Function GetInitVectorBits: TMemSize;
    Function GetKeyBits: TMemSize;
    Function GetBlockBits: TMemSize;
  protected
    procedure BlocksXOR(const Src1,Src2; out Dest); virtual;
    procedure BlocksCopy(const Src; out Dest); virtual;
    procedure Update_ECB(const Input; out Output); virtual;
    procedure Update_CBC(const Input; out Output); virtual;
    procedure Update_PCBC(const Input; out Output); virtual;
    procedure Update_CFB(const Input; out Output); virtual;
    procedure Update_OFB(const Input; out Output); virtual;
    procedure Update_CTR(const Input; out Output); virtual;
    procedure PrepareUpdateProc; virtual;
    procedure DoOnProgress(Progress: Single); virtual;
    procedure CipherInit; virtual; abstract;
    procedure CipherFinal; virtual; abstract;
    procedure Encrypt(const Input; out Output); virtual; abstract;
    procedure Decrypt(const Input; out Output); virtual; abstract;
  public
    constructor Create(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); overload; virtual;
    constructor Create(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); overload; virtual;
    constructor Create; overload; virtual;
    destructor Destroy; override;
    procedure Init(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); overload; virtual;
    procedure Init(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); overload; virtual;
    procedure Update(const Input; out Output); virtual;
    Function Final(const Input; InputSize: TMemSize; out Output; OutputFullBlock: Boolean = True): TMemSize; virtual;
    Function OutputSize(InputSize: TMemSize; FullLastBlock: Boolean = True): TMemSize; virtual;
    procedure ProcessBytes(const Input; InputSize: TMemSize; out Output); overload; virtual;
    procedure ProcessBytes(var Buff; Size: TMemSize); overload; virtual;
    procedure ProcessStream(Input, Output: TStream); overload; virtual;
    procedure ProcessStream(Stream: TStream); overload; virtual;
    procedure ProcessFile(const InputFileName, OutputFileName: String); overload; virtual;
    procedure ProcessFile(const FileName: String); overload; virtual;
    property InitVector: Pointer read fInitVector;
    property Key: Pointer read fKey;
  published
    property Mode: TBCMode read fMode;
    property ModeOfOperation: TBCModeOfOperation read fModeOfOperation write fModeOfOperation;
    property Padding: TBCPadding read fPadding write fPadding;
    property InitVectorBytes: TMemSize read fInitVectorBytes;
    property InitVectorBits: TMemSize read GetInitVectorBits;
    property KeyBytes: TMemSize read fKeyBytes;
    property KeyBits: TMemSize read GetKeyBits;
    property BlockBytes: TMemSize read fBlockBytes;
    property BlockBits: TMemSize read GetBlockBits;
    property OnProgress: TProgressEvent read fOnProgress write fOnProgress;
  end;

//******************************************************************************

  TRijLength  = (rl128bit,rl160bit,rl192bit,rl224bit,rl256bit);

  TRijWord        = UInt32;
  TRijKey         = array[0..31] of Byte;      {256 bits}
  TRijKeySchedule = array[0..119] of TRijWord;
  TRijState       = array[0..7] of TRijWord;   {256 bits}

  TRijndaelCipher = class(TBlockCipher)
  private
    fKeyLength:   TRijLength;
    fBlockLength: TRijLength;
    fNk:          Integer;    // length of the key in words
    fNb:          Integer;    // length of the block in words
    fNr:          Integer;    // number of rounds (function of Nk an Nb)
    fRijKey:      TRijKey;
    fKeySchedule: TRijKeySchedule;
  protected
    procedure SetKeyLength(Value: TRijLength); virtual;
    procedure SetBlockLength(Value: TRijLength); virtual;
    procedure CipherInit; override;
    procedure CipherFinal; override;
    procedure Encrypt(const Input; out Output); override;
    procedure Decrypt(const Input; out Output); override;
  public
    constructor Create(const Key; const InitVector; KeyLength, BlockLength: TRijLength; Mode: TBCMode); overload;
    constructor Create(const Key; KeyLength, BlockLength: TRijLength; Mode: TBCMode); overload;
    procedure Init(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); override;
    procedure Init(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode); override;
    procedure Init(const Key; const InitVector; KeyLength, BlockLength: TRijLength; Mode: TBCMode); overload; virtual;
    procedure Init(const Key; KeyLength, BlockLength: TRijLength; Mode: TBCMode); overload; virtual;
  published
    property KeyLength: TRijLength read fKeyLength;
    property BlockLength: TRijLength read fBlockLength;
    property Nk: Integer read fNk;
    property Nb: Integer read fNb;
    property Nr: Integer read fNr;
  end;  

implementation

uses
  SysUtils, Math;

Function TBlockCipher.GetInitVectorBits: TMemSize;
begin
Result := TMemSize(fInitVectorBytes shl 3);
end;

//------------------------------------------------------------------------------

Function TBlockCipher.GetKeyBits: TMemSize;
begin
Result := TMemSize(fKeyBytes shl 3);
end;

//------------------------------------------------------------------------------

Function TBlockCipher.GetBlockBits: TMemSize;
begin
Result := TMemSize(fBlockBytes shl 3);
end;

//==============================================================================

procedure TBlockCipher.BlocksXOR(const Src1,Src2; out Dest);
var
  i:  PtrUInt;
begin
If fBlockBytes > 0 then
  For i := 0 to Pred(fBlockBytes) do
    PByte(PtrUInt(@Dest) + i)^ := PByte(PtrUInt(@Src1) + i)^ xor PByte(PtrUInt(@Src2) + i)^;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.BlocksCopy(const Src; out Dest);
begin
Move(Src,Dest,fBlockBytes);
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_ECB(const Input; out Output);
begin
case fMode of
  cmEncrypt:  Encrypt(Input,Output);
  cmDecrypt:  Decrypt(Input,Output);
end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_CBC(const Input; out Output);
begin
case fMode of
  cmEncrypt:
    begin
      BlocksXOR(Input,fInitVector^,fTempBlock^);
      Encrypt(fTempBlock^,Output);
      BlocksCopy(Output,fInitVector^);
    end;
  cmDecrypt:
    begin
      BlocksCopy(Input,fTempBlock^);
      Decrypt(Input,Output);
      BlocksXOR(Output,fInitVector^,Output);
      BlocksCopy(fTempBlock^,fInitVector^);
    end;
end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_PCBC(const Input; out Output);
begin
case fMode of
  cmEncrypt:
    begin
      BlocksXOR(Input,fInitVector^,fTempBlock^);
      BlocksCopy(Input,fInitVector^);
      Encrypt(fTempBlock^,Output);
      BlocksXOR(Output,fInitVector^,fInitVector^);
    end;
  cmDecrypt:
    begin
      Decrypt(Input,fTempBlock^);
      BlocksXOR(fTempBlock^,fInitVector^,fTempBlock^);
      BlocksXOR(Input,fTempBlock^,fInitVector^);
      BlocksCopy(fTempBlock^,Output);
    end;
end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_CFB(const Input; out Output);
begin
case fMode of
  cmEncrypt:
    begin
      Encrypt(fInitVector^,fTempBlock^);
      BlocksXOR(fTempBlock^,Input,Output);
      BlocksCopy(Output,fInitVector^);
    end;
  cmDecrypt:
    begin
      Encrypt(fInitVector^,fTempBlock^);
      BlocksCopy(Input,fInitVector^);
      BlocksXOR(fTempBlock^,Input,Output);
    end;
end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_OFB(const Input; out Output);
begin
Encrypt(fInitVector^,fInitVector^);
BlocksXOR(Input,fInitVector^,Output);
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update_CTR(const Input; out Output);
begin
If BlockBytes >= 8 then
  begin
    Encrypt(fInitVector^,fTempBlock^);
    BlocksXOR(Input,fTempBlock^,Output);
  {$IFDEF OverflowCheck}{$Q-}{$ENDIF}
    Inc(Int64(fInitVector^));
  {$IFDEF OverflowCheck}{$Q+}{$ENDIF}  
  end
else raise Exception.CreateFmt('TBlockCipher.Update_CTR: Too small block (%d).',[fBlockBytes]);
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.PrepareUpdateProc;
begin
case fModeOfOperation of
  moECB:  fUpdateProc := Update_ECB;
  moCBC:  fUpdateProc := Update_CBC;
  moPCBC: fUpdateProc := Update_PCBC;
  moCFB:  fUpdateProc := Update_CFB;
  moOFB:  fUpdateProc := Update_OFB;
  moCTR:  fUpdateProc := Update_CTR;
else
  raise Exception.CreateFmt('TBlockCipher.PrepareUpdateProc: Unknown mode of operation (%d).',[Ord(fModeOfOperation)]);
end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.DoOnProgress(Progress: Single);
begin
If Assigned(fOnProgress) then fOnProgress(Self,Progress);
end;

//==============================================================================

constructor TBlockCipher.Create(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
Create;
Init(Key,InitVector,KeyBytes,BlockBytes,Mode);
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

constructor TBlockCipher.Create(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
Create;
Init(Key,KeyBytes,BlockBytes,Mode);
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

constructor TBlockCipher.Create;
begin
inherited Create;
fMode := cmUndefined;
fModeOfOperation := moECB;
fPadding := padZeroes;
fInitVector := nil;
fInitVectorBytes := 0;
fKey := nil;
fKeyBytes := 0;
fTempBlock := nil;
fBlockBytes := 0;
end;

//------------------------------------------------------------------------------


destructor TBlockCipher.Destroy;
begin
CipherFinal;
If Assigned(fTempBlock) and (fBlockBytes > 0) then
  FreeMem(fTempBlock,fBlockBytes);
inherited;  
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Init(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
If (KeyBytes > 0) and (BlockBytes > 0) then
  begin
    fMode := Mode;
    ReallocMem(fKey,KeyBytes);
    Move(Key,fKey^,KeyBytes);
    fKeyBytes := KeyBytes;
    ReallocMem(fInitVector,BlockBytes);
    ReallocMem(fTempBlock,BlockBytes);
    Move(InitVector,fInitVector^,BlockBytes);
    fBlockBytes := BlockBytes;
    PrepareUpdateProc;
    CipherInit;
  end
else raise Exception.CreateFmt('TBlockCipher.Init: Size of key (%d) and blocks (%d) must be larger than zero.',[KeyBytes, BlockBytes]);
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TBlockCipher.Init(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
If (KeyBytes > 0) and (BlockBytes > 0) then
  begin
    fMode := Mode;
    ReallocMem(fKey,KeyBytes);
    Move(Key,fKey^,KeyBytes);
    fKeyBytes := KeyBytes;
    ReallocMem(fInitVector,BlockBytes);
    FillChar(fInitVector^,BlockBytes,0);
    ReallocMem(fTempBlock,BlockBytes);
    fBlockBytes := BlockBytes;
    PrepareUpdateProc;
    CipherInit;
  end
else raise Exception.CreateFmt('TBlockCipher.Init: Size of key (%d) and blocks (%d) must be larger than zero.',[KeyBytes, BlockBytes]);
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.Update(const Input; out Output);
begin
If fMode in [cmEncrypt,cmDecrypt] then
  fUpdateProc(Input,Output)
else
  raise Exception.CreateFmt('TBlockCipher.Update: Undefined or unknown mode (%d).',[Ord(fMode)]);
end;

//------------------------------------------------------------------------------

Function TBlockCipher.Final(const Input; InputSize: TMemSize; out Output; OutputFullBlock: Boolean = True): TMemSize;
begin
If InputSize > fBlockBytes then
  raise Exception.CreateFmt('TBlockCipher.Final:  Input buffer is too large (%d/%d).',[InputSize,fBlockBytes]);
If InputSize < fBlockBytes then
  case fPadding of
    padPKCS7: FillChar(fTempBlock^,fBlockBytes,Byte(fBlockBytes - InputSize));
  else
   {padZeroes}FillChar(fTempBlock^,fBlockBytes,0);
  end;
Move(Input,fTempBlock^,InputSize);
If not OutputFullBlock and (fModeOfOperation in [moCFB,moOFB,moCTR]) then
  begin
    Update(fTempBlock^,fTempBlock^);
    Move(fTempBlock^,Output,InputSize);
    Result := InputSize;
  end
else
  begin
    Update(fTempBlock^,Output);
    Result := fBlockBytes;
  end;
end;

//------------------------------------------------------------------------------

Function TBlockCipher.OutputSize(InputSize: TMemSize; FullLastBlock: Boolean = True): TMemSize;
begin
If not FullLastBlock and (fModeOfOperation in [moCFB,moOFB,moCTR]) then
  Result := InputSize
else
  Result := TMemSize(Ceil(InputSize / fBlockBytes)) * fBlockBytes;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.ProcessBytes(const Input; InputSize: TMemSize; out Output);
var
  Offset:     TMemSize;
  BytesLeft:  TMemSize;
begin
If InputSize > 0 then
  begin
    Offset := 0;
    BytesLeft := InputSize;
    DoOnProgress(0.0);
    while BytesLeft > fBlockBytes do
      begin
        Update(Pointer(PtrUInt(@Input) + Offset)^,Pointer(PtrUInt(@Output) + Offset)^);
        Dec(BytesLeft,fBlockBytes);
        Inc(Offset,fBlockBytes);
        DoOnProgress(BytesLeft / InputSize);
      end;
    If BytesLeft > 0 then
      Final(Pointer(PtrUInt(@Input) + Offset)^,BytesLeft,Pointer(PtrUInt(@Output) + Offset)^);
    DoOnProgress(1.0);
  end;
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TBlockCipher.ProcessBytes(var Buff; Size: TMemSize);
begin
ProcessBytes(Buff,Size,Buff);
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.ProcessStream(Input, Output: TStream);
var
  Buffer:         Pointer;
  BytesRead:      TMemSize;
  ProgressStart:  Int64;
begin
If Input = Output then
  ProcessStream(Input)
else
  begin
    If (Input.Size - Input.Position) > 0 then
      begin
        GetMem(Buffer,fBlockBytes);
        try
          DoOnProgress(0.0);
          ProgressStart := Input.Position;
          repeat
            BytesRead := Input.Read(Buffer^,fBlockBytes);
            If BytesRead > 0 then
              begin
                If BytesRead < fBlockBytes then
                  BytesRead := Final(Buffer^,BytesRead,Buffer^)
                else
                  Update(Buffer^,Buffer^);
                Output.WriteBuffer(Buffer^,BytesRead);
              end;
            DoOnProgress((Input.Position - ProgressStart) / (Input.Size - ProgressStart));
          until BytesRead < fBlockBytes;
          DoOnProgress(1.0);
        finally
          FreeMem(Buffer,fBlockBytes);
        end;
      end;
  end;
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TBlockCipher.ProcessStream(Stream: TStream);
var
  Buffer:         Pointer;
  BytesRead:      TMemSize;
  BlockStart:     Int64;
  ProgressStart:  Int64;
begin
If (Stream.Size - Stream.Position) > 0 then
  begin
    GetMem(Buffer,fBlockBytes);
    try
      DoOnProgress(0.0);
      ProgressStart := Stream.Position;
      repeat
        BlockStart := Stream.Position;
        BytesRead := Stream.Read(Buffer^,fBlockBytes);
        If BytesRead > 0 then
          begin
            If BytesRead < fBlockBytes then
              BytesRead := Final(Buffer^,BytesRead,Buffer^)
            else
              Update(Buffer^,Buffer^);
            Stream.Position := BlockStart;
            Stream.WriteBuffer(Buffer^,BytesRead);
          end;
        DoOnProgress((Stream.Position - ProgressStart) / (Stream.Size - ProgressStart));
      until BytesRead < fBlockBytes;
      DoOnProgress(1.0);
    finally
      FreeMem(Buffer,fBlockBytes);
    end;
  end;
end;

//------------------------------------------------------------------------------

procedure TBlockCipher.ProcessFile(const InputFileName, OutputFileName: String);
var
  InputStream:  TFileStream;
  OutputStream: TFileStream;
begin
If AnsiSameText(InputFileName,OutputFileName) then
  ProcessFile(InputFileName)
else
  begin
    InputStream := TFileStream.Create(InputFileName,fmOpenRead or fmShareDenyWrite);
    try
      OutputStream := TFileStream.Create(OutputFileName,fmCreate or fmShareExclusive);
      try
        ProcessStream(InputStream,OutputStream);
      finally
        OutputStream.Free;
      end;
    finally
      InputStream.Free;
    end;
  end;
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TBlockCipher.ProcessFile(const FileName: String);
var
  FileStream: TFileStream;
begin
FileStream := TFileStream.Create(FileName,fmOpenReadWrite or fmShareExclusive);
try
  ProcessStream(FileStream);
finally
  FileStream.Free;
end;
end;

{==============================================================================}
{    Rijndael cipher lookup tables                                             }
{==============================================================================}
// Equivalent Inverse Cipher
const
  EncTab1: Array[Byte] of TRijWord = (
    $A56363C6, $847C7CF8, $997777EE, $8D7B7BF6, $0DF2F2FF, $BD6B6BD6, $B16F6FDE, $54C5C591,
    $50303060, $03010102, $A96767CE, $7D2B2B56, $19FEFEE7, $62D7D7B5, $E6ABAB4D, $9A7676EC,
    $45CACA8F, $9D82821F, $40C9C989, $877D7DFA, $15FAFAEF, $EB5959B2, $C947478E, $0BF0F0FB,
    $ECADAD41, $67D4D4B3, $FDA2A25F, $EAAFAF45, $BF9C9C23, $F7A4A453, $967272E4, $5BC0C09B,
    $C2B7B775, $1CFDFDE1, $AE93933D, $6A26264C, $5A36366C, $413F3F7E, $02F7F7F5, $4FCCCC83,
    $5C343468, $F4A5A551, $34E5E5D1, $08F1F1F9, $937171E2, $73D8D8AB, $53313162, $3F15152A,
    $0C040408, $52C7C795, $65232346, $5EC3C39D, $28181830, $A1969637, $0F05050A, $B59A9A2F,
    $0907070E, $36121224, $9B80801B, $3DE2E2DF, $26EBEBCD, $6927274E, $CDB2B27F, $9F7575EA,
    $1B090912, $9E83831D, $742C2C58, $2E1A1A34, $2D1B1B36, $B26E6EDC, $EE5A5AB4, $FBA0A05B,
    $F65252A4, $4D3B3B76, $61D6D6B7, $CEB3B37D, $7B292952, $3EE3E3DD, $712F2F5E, $97848413,
    $F55353A6, $68D1D1B9, $00000000, $2CEDEDC1, $60202040, $1FFCFCE3, $C8B1B179, $ED5B5BB6,
    $BE6A6AD4, $46CBCB8D, $D9BEBE67, $4B393972, $DE4A4A94, $D44C4C98, $E85858B0, $4ACFCF85,
    $6BD0D0BB, $2AEFEFC5, $E5AAAA4F, $16FBFBED, $C5434386, $D74D4D9A, $55333366, $94858511,
    $CF45458A, $10F9F9E9, $06020204, $817F7FFE, $F05050A0, $443C3C78, $BA9F9F25, $E3A8A84B,
    $F35151A2, $FEA3A35D, $C0404080, $8A8F8F05, $AD92923F, $BC9D9D21, $48383870, $04F5F5F1,
    $DFBCBC63, $C1B6B677, $75DADAAF, $63212142, $30101020, $1AFFFFE5, $0EF3F3FD, $6DD2D2BF,
    $4CCDCD81, $140C0C18, $35131326, $2FECECC3, $E15F5FBE, $A2979735, $CC444488, $3917172E,
    $57C4C493, $F2A7A755, $827E7EFC, $473D3D7A, $AC6464C8, $E75D5DBA, $2B191932, $957373E6,
    $A06060C0, $98818119, $D14F4F9E, $7FDCDCA3, $66222244, $7E2A2A54, $AB90903B, $8388880B,
    $CA46468C, $29EEEEC7, $D3B8B86B, $3C141428, $79DEDEA7, $E25E5EBC, $1D0B0B16, $76DBDBAD,
    $3BE0E0DB, $56323264, $4E3A3A74, $1E0A0A14, $DB494992, $0A06060C, $6C242448, $E45C5CB8,
    $5DC2C29F, $6ED3D3BD, $EFACAC43, $A66262C4, $A8919139, $A4959531, $37E4E4D3, $8B7979F2,
    $32E7E7D5, $43C8C88B, $5937376E, $B76D6DDA, $8C8D8D01, $64D5D5B1, $D24E4E9C, $E0A9A949,
    $B46C6CD8, $FA5656AC, $07F4F4F3, $25EAEACF, $AF6565CA, $8E7A7AF4, $E9AEAE47, $18080810,
    $D5BABA6F, $887878F0, $6F25254A, $722E2E5C, $241C1C38, $F1A6A657, $C7B4B473, $51C6C697,
    $23E8E8CB, $7CDDDDA1, $9C7474E8, $211F1F3E, $DD4B4B96, $DCBDBD61, $868B8B0D, $858A8A0F,
    $907070E0, $423E3E7C, $C4B5B571, $AA6666CC, $D8484890, $05030306, $01F6F6F7, $120E0E1C,
    $A36161C2, $5F35356A, $F95757AE, $D0B9B969, $91868617, $58C1C199, $271D1D3A, $B99E9E27,
    $38E1E1D9, $13F8F8EB, $B398982B, $33111122, $BB6969D2, $70D9D9A9, $898E8E07, $A7949433,
    $B69B9B2D, $221E1E3C, $92878715, $20E9E9C9, $49CECE87, $FF5555AA, $78282850, $7ADFDFA5,
    $8F8C8C03, $F8A1A159, $80898909, $170D0D1A, $DABFBF65, $31E6E6D7, $C6424284, $B86868D0,
    $C3414182, $B0999929, $772D2D5A, $110F0F1E, $CBB0B07B, $FC5454A8, $D6BBBB6D, $3A16162C);

  EncTab2: Array[Byte] of TRijWord = (
    $6363C6A5, $7C7CF884, $7777EE99, $7B7BF68D, $F2F2FF0D, $6B6BD6BD, $6F6FDEB1, $C5C59154,
    $30306050, $01010203, $6767CEA9, $2B2B567D, $FEFEE719, $D7D7B562, $ABAB4DE6, $7676EC9A,
    $CACA8F45, $82821F9D, $C9C98940, $7D7DFA87, $FAFAEF15, $5959B2EB, $47478EC9, $F0F0FB0B,
    $ADAD41EC, $D4D4B367, $A2A25FFD, $AFAF45EA, $9C9C23BF, $A4A453F7, $7272E496, $C0C09B5B,
    $B7B775C2, $FDFDE11C, $93933DAE, $26264C6A, $36366C5A, $3F3F7E41, $F7F7F502, $CCCC834F,
    $3434685C, $A5A551F4, $E5E5D134, $F1F1F908, $7171E293, $D8D8AB73, $31316253, $15152A3F,
    $0404080C, $C7C79552, $23234665, $C3C39D5E, $18183028, $969637A1, $05050A0F, $9A9A2FB5,
    $07070E09, $12122436, $80801B9B, $E2E2DF3D, $EBEBCD26, $27274E69, $B2B27FCD, $7575EA9F,
    $0909121B, $83831D9E, $2C2C5874, $1A1A342E, $1B1B362D, $6E6EDCB2, $5A5AB4EE, $A0A05BFB,
    $5252A4F6, $3B3B764D, $D6D6B761, $B3B37DCE, $2929527B, $E3E3DD3E, $2F2F5E71, $84841397,
    $5353A6F5, $D1D1B968, $00000000, $EDEDC12C, $20204060, $FCFCE31F, $B1B179C8, $5B5BB6ED,
    $6A6AD4BE, $CBCB8D46, $BEBE67D9, $3939724B, $4A4A94DE, $4C4C98D4, $5858B0E8, $CFCF854A,
    $D0D0BB6B, $EFEFC52A, $AAAA4FE5, $FBFBED16, $434386C5, $4D4D9AD7, $33336655, $85851194,
    $45458ACF, $F9F9E910, $02020406, $7F7FFE81, $5050A0F0, $3C3C7844, $9F9F25BA, $A8A84BE3,
    $5151A2F3, $A3A35DFE, $404080C0, $8F8F058A, $92923FAD, $9D9D21BC, $38387048, $F5F5F104,
    $BCBC63DF, $B6B677C1, $DADAAF75, $21214263, $10102030, $FFFFE51A, $F3F3FD0E, $D2D2BF6D,
    $CDCD814C, $0C0C1814, $13132635, $ECECC32F, $5F5FBEE1, $979735A2, $444488CC, $17172E39,
    $C4C49357, $A7A755F2, $7E7EFC82, $3D3D7A47, $6464C8AC, $5D5DBAE7, $1919322B, $7373E695,
    $6060C0A0, $81811998, $4F4F9ED1, $DCDCA37F, $22224466, $2A2A547E, $90903BAB, $88880B83,
    $46468CCA, $EEEEC729, $B8B86BD3, $1414283C, $DEDEA779, $5E5EBCE2, $0B0B161D, $DBDBAD76,
    $E0E0DB3B, $32326456, $3A3A744E, $0A0A141E, $494992DB, $06060C0A, $2424486C, $5C5CB8E4,
    $C2C29F5D, $D3D3BD6E, $ACAC43EF, $6262C4A6, $919139A8, $959531A4, $E4E4D337, $7979F28B,
    $E7E7D532, $C8C88B43, $37376E59, $6D6DDAB7, $8D8D018C, $D5D5B164, $4E4E9CD2, $A9A949E0,
    $6C6CD8B4, $5656ACFA, $F4F4F307, $EAEACF25, $6565CAAF, $7A7AF48E, $AEAE47E9, $08081018,
    $BABA6FD5, $7878F088, $25254A6F, $2E2E5C72, $1C1C3824, $A6A657F1, $B4B473C7, $C6C69751,
    $E8E8CB23, $DDDDA17C, $7474E89C, $1F1F3E21, $4B4B96DD, $BDBD61DC, $8B8B0D86, $8A8A0F85,
    $7070E090, $3E3E7C42, $B5B571C4, $6666CCAA, $484890D8, $03030605, $F6F6F701, $0E0E1C12,
    $6161C2A3, $35356A5F, $5757AEF9, $B9B969D0, $86861791, $C1C19958, $1D1D3A27, $9E9E27B9,
    $E1E1D938, $F8F8EB13, $98982BB3, $11112233, $6969D2BB, $D9D9A970, $8E8E0789, $949433A7,
    $9B9B2DB6, $1E1E3C22, $87871592, $E9E9C920, $CECE8749, $5555AAFF, $28285078, $DFDFA57A,
    $8C8C038F, $A1A159F8, $89890980, $0D0D1A17, $BFBF65DA, $E6E6D731, $424284C6, $6868D0B8,
    $414182C3, $999929B0, $2D2D5A77, $0F0F1E11, $B0B07BCB, $5454A8FC, $BBBB6DD6, $16162C3A);

  EncTab3: Array[Byte] of TRijWord = (
    $63C6A563, $7CF8847C, $77EE9977, $7BF68D7B, $F2FF0DF2, $6BD6BD6B, $6FDEB16F, $C59154C5,
    $30605030, $01020301, $67CEA967, $2B567D2B, $FEE719FE, $D7B562D7, $AB4DE6AB, $76EC9A76,
    $CA8F45CA, $821F9D82, $C98940C9, $7DFA877D, $FAEF15FA, $59B2EB59, $478EC947, $F0FB0BF0,
    $AD41ECAD, $D4B367D4, $A25FFDA2, $AF45EAAF, $9C23BF9C, $A453F7A4, $72E49672, $C09B5BC0,
    $B775C2B7, $FDE11CFD, $933DAE93, $264C6A26, $366C5A36, $3F7E413F, $F7F502F7, $CC834FCC,
    $34685C34, $A551F4A5, $E5D134E5, $F1F908F1, $71E29371, $D8AB73D8, $31625331, $152A3F15,
    $04080C04, $C79552C7, $23466523, $C39D5EC3, $18302818, $9637A196, $050A0F05, $9A2FB59A,
    $070E0907, $12243612, $801B9B80, $E2DF3DE2, $EBCD26EB, $274E6927, $B27FCDB2, $75EA9F75,
    $09121B09, $831D9E83, $2C58742C, $1A342E1A, $1B362D1B, $6EDCB26E, $5AB4EE5A, $A05BFBA0,
    $52A4F652, $3B764D3B, $D6B761D6, $B37DCEB3, $29527B29, $E3DD3EE3, $2F5E712F, $84139784,
    $53A6F553, $D1B968D1, $00000000, $EDC12CED, $20406020, $FCE31FFC, $B179C8B1, $5BB6ED5B,
    $6AD4BE6A, $CB8D46CB, $BE67D9BE, $39724B39, $4A94DE4A, $4C98D44C, $58B0E858, $CF854ACF,
    $D0BB6BD0, $EFC52AEF, $AA4FE5AA, $FBED16FB, $4386C543, $4D9AD74D, $33665533, $85119485,
    $458ACF45, $F9E910F9, $02040602, $7FFE817F, $50A0F050, $3C78443C, $9F25BA9F, $A84BE3A8,
    $51A2F351, $A35DFEA3, $4080C040, $8F058A8F, $923FAD92, $9D21BC9D, $38704838, $F5F104F5,
    $BC63DFBC, $B677C1B6, $DAAF75DA, $21426321, $10203010, $FFE51AFF, $F3FD0EF3, $D2BF6DD2,
    $CD814CCD, $0C18140C, $13263513, $ECC32FEC, $5FBEE15F, $9735A297, $4488CC44, $172E3917,
    $C49357C4, $A755F2A7, $7EFC827E, $3D7A473D, $64C8AC64, $5DBAE75D, $19322B19, $73E69573,
    $60C0A060, $81199881, $4F9ED14F, $DCA37FDC, $22446622, $2A547E2A, $903BAB90, $880B8388,
    $468CCA46, $EEC729EE, $B86BD3B8, $14283C14, $DEA779DE, $5EBCE25E, $0B161D0B, $DBAD76DB,
    $E0DB3BE0, $32645632, $3A744E3A, $0A141E0A, $4992DB49, $060C0A06, $24486C24, $5CB8E45C,
    $C29F5DC2, $D3BD6ED3, $AC43EFAC, $62C4A662, $9139A891, $9531A495, $E4D337E4, $79F28B79,
    $E7D532E7, $C88B43C8, $376E5937, $6DDAB76D, $8D018C8D, $D5B164D5, $4E9CD24E, $A949E0A9,
    $6CD8B46C, $56ACFA56, $F4F307F4, $EACF25EA, $65CAAF65, $7AF48E7A, $AE47E9AE, $08101808,
    $BA6FD5BA, $78F08878, $254A6F25, $2E5C722E, $1C38241C, $A657F1A6, $B473C7B4, $C69751C6,
    $E8CB23E8, $DDA17CDD, $74E89C74, $1F3E211F, $4B96DD4B, $BD61DCBD, $8B0D868B, $8A0F858A,
    $70E09070, $3E7C423E, $B571C4B5, $66CCAA66, $4890D848, $03060503, $F6F701F6, $0E1C120E,
    $61C2A361, $356A5F35, $57AEF957, $B969D0B9, $86179186, $C19958C1, $1D3A271D, $9E27B99E,
    $E1D938E1, $F8EB13F8, $982BB398, $11223311, $69D2BB69, $D9A970D9, $8E07898E, $9433A794,
    $9B2DB69B, $1E3C221E, $87159287, $E9C920E9, $CE8749CE, $55AAFF55, $28507828, $DFA57ADF,
    $8C038F8C, $A159F8A1, $89098089, $0D1A170D, $BF65DABF, $E6D731E6, $4284C642, $68D0B868,
    $4182C341, $9929B099, $2D5A772D, $0F1E110F, $B07BCBB0, $54A8FC54, $BB6DD6BB, $162C3A16);

  EncTab4: Array[Byte] of TRijWord = (
    $C6A56363, $F8847C7C, $EE997777, $F68D7B7B, $FF0DF2F2, $D6BD6B6B, $DEB16F6F, $9154C5C5,
    $60503030, $02030101, $CEA96767, $567D2B2B, $E719FEFE, $B562D7D7, $4DE6ABAB, $EC9A7676,
    $8F45CACA, $1F9D8282, $8940C9C9, $FA877D7D, $EF15FAFA, $B2EB5959, $8EC94747, $FB0BF0F0,
    $41ECADAD, $B367D4D4, $5FFDA2A2, $45EAAFAF, $23BF9C9C, $53F7A4A4, $E4967272, $9B5BC0C0,
    $75C2B7B7, $E11CFDFD, $3DAE9393, $4C6A2626, $6C5A3636, $7E413F3F, $F502F7F7, $834FCCCC,
    $685C3434, $51F4A5A5, $D134E5E5, $F908F1F1, $E2937171, $AB73D8D8, $62533131, $2A3F1515,
    $080C0404, $9552C7C7, $46652323, $9D5EC3C3, $30281818, $37A19696, $0A0F0505, $2FB59A9A,
    $0E090707, $24361212, $1B9B8080, $DF3DE2E2, $CD26EBEB, $4E692727, $7FCDB2B2, $EA9F7575,
    $121B0909, $1D9E8383, $58742C2C, $342E1A1A, $362D1B1B, $DCB26E6E, $B4EE5A5A, $5BFBA0A0,
    $A4F65252, $764D3B3B, $B761D6D6, $7DCEB3B3, $527B2929, $DD3EE3E3, $5E712F2F, $13978484,
    $A6F55353, $B968D1D1, $00000000, $C12CEDED, $40602020, $E31FFCFC, $79C8B1B1, $B6ED5B5B,
    $D4BE6A6A, $8D46CBCB, $67D9BEBE, $724B3939, $94DE4A4A, $98D44C4C, $B0E85858, $854ACFCF,
    $BB6BD0D0, $C52AEFEF, $4FE5AAAA, $ED16FBFB, $86C54343, $9AD74D4D, $66553333, $11948585,
    $8ACF4545, $E910F9F9, $04060202, $FE817F7F, $A0F05050, $78443C3C, $25BA9F9F, $4BE3A8A8,
    $A2F35151, $5DFEA3A3, $80C04040, $058A8F8F, $3FAD9292, $21BC9D9D, $70483838, $F104F5F5,
    $63DFBCBC, $77C1B6B6, $AF75DADA, $42632121, $20301010, $E51AFFFF, $FD0EF3F3, $BF6DD2D2,
    $814CCDCD, $18140C0C, $26351313, $C32FECEC, $BEE15F5F, $35A29797, $88CC4444, $2E391717,
    $9357C4C4, $55F2A7A7, $FC827E7E, $7A473D3D, $C8AC6464, $BAE75D5D, $322B1919, $E6957373,
    $C0A06060, $19988181, $9ED14F4F, $A37FDCDC, $44662222, $547E2A2A, $3BAB9090, $0B838888,
    $8CCA4646, $C729EEEE, $6BD3B8B8, $283C1414, $A779DEDE, $BCE25E5E, $161D0B0B, $AD76DBDB,
    $DB3BE0E0, $64563232, $744E3A3A, $141E0A0A, $92DB4949, $0C0A0606, $486C2424, $B8E45C5C,
    $9F5DC2C2, $BD6ED3D3, $43EFACAC, $C4A66262, $39A89191, $31A49595, $D337E4E4, $F28B7979,
    $D532E7E7, $8B43C8C8, $6E593737, $DAB76D6D, $018C8D8D, $B164D5D5, $9CD24E4E, $49E0A9A9,
    $D8B46C6C, $ACFA5656, $F307F4F4, $CF25EAEA, $CAAF6565, $F48E7A7A, $47E9AEAE, $10180808,
    $6FD5BABA, $F0887878, $4A6F2525, $5C722E2E, $38241C1C, $57F1A6A6, $73C7B4B4, $9751C6C6,
    $CB23E8E8, $A17CDDDD, $E89C7474, $3E211F1F, $96DD4B4B, $61DCBDBD, $0D868B8B, $0F858A8A,
    $E0907070, $7C423E3E, $71C4B5B5, $CCAA6666, $90D84848, $06050303, $F701F6F6, $1C120E0E,
    $C2A36161, $6A5F3535, $AEF95757, $69D0B9B9, $17918686, $9958C1C1, $3A271D1D, $27B99E9E,
    $D938E1E1, $EB13F8F8, $2BB39898, $22331111, $D2BB6969, $A970D9D9, $07898E8E, $33A79494,
    $2DB69B9B, $3C221E1E, $15928787, $C920E9E9, $8749CECE, $AAFF5555, $50782828, $A57ADFDF,
    $038F8C8C, $59F8A1A1, $09808989, $1A170D0D, $65DABFBF, $D731E6E6, $84C64242, $D0B86868,
    $82C34141, $29B09999, $5A772D2D, $1E110F0F, $7BCBB0B0, $A8FC5454, $6DD6BBBB, $2C3A1616);

  DecTab1: Array[Byte] of TRijWord = (
    $50A7F451, $5365417E, $C3A4171A, $965E273A, $CB6BAB3B, $F1459D1F, $AB58FAAC, $9303E34B,
    $55FA3020, $F66D76AD, $9176CC88, $254C02F5, $FCD7E54F, $D7CB2AC5, $80443526, $8FA362B5,
    $495AB1DE, $671BBA25, $980EEA45, $E1C0FE5D, $02752FC3, $12F04C81, $A397468D, $C6F9D36B,
    $E75F8F03, $959C9215, $EB7A6DBF, $DA595295, $2D83BED4, $D3217458, $2969E049, $44C8C98E,
    $6A89C275, $78798EF4, $6B3E5899, $DD71B927, $B64FE1BE, $17AD88F0, $66AC20C9, $B43ACE7D,
    $184ADF63, $82311AE5, $60335197, $457F5362, $E07764B1, $84AE6BBB, $1CA081FE, $942B08F9,
    $58684870, $19FD458F, $876CDE94, $B7F87B52, $23D373AB, $E2024B72, $578F1FE3, $2AAB5566,
    $0728EBB2, $03C2B52F, $9A7BC586, $A50837D3, $F2872830, $B2A5BF23, $BA6A0302, $5C8216ED,
    $2B1CCF8A, $92B479A7, $F0F207F3, $A1E2694E, $CDF4DA65, $D5BE0506, $1F6234D1, $8AFEA6C4,
    $9D532E34, $A055F3A2, $32E18A05, $75EBF6A4, $39EC830B, $AAEF6040, $069F715E, $51106EBD,
    $F98A213E, $3D06DD96, $AE053EDD, $46BDE64D, $B58D5491, $055DC471, $6FD40604, $FF155060,
    $24FB9819, $97E9BDD6, $CC434089, $779ED967, $BD42E8B0, $888B8907, $385B19E7, $DBEEC879,
    $470A7CA1, $E90F427C, $C91E84F8, $00000000, $83868009, $48ED2B32, $AC70111E, $4E725A6C,
    $FBFF0EFD, $5638850F, $1ED5AE3D, $27392D36, $64D90F0A, $21A65C68, $D1545B9B, $3A2E3624,
    $B1670A0C, $0FE75793, $D296EEB4, $9E919B1B, $4FC5C080, $A220DC61, $694B775A, $161A121C,
    $0ABA93E2, $E52AA0C0, $43E0223C, $1D171B12, $0B0D090E, $ADC78BF2, $B9A8B62D, $C8A91E14,
    $8519F157, $4C0775AF, $BBDD99EE, $FD607FA3, $9F2601F7, $BCF5725C, $C53B6644, $347EFB5B,
    $7629438B, $DCC623CB, $68FCEDB6, $63F1E4B8, $CADC31D7, $10856342, $40229713, $2011C684,
    $7D244A85, $F83DBBD2, $1132F9AE, $6DA129C7, $4B2F9E1D, $F330B2DC, $EC52860D, $D0E3C177,
    $6C16B32B, $99B970A9, $FA489411, $2264E947, $C48CFCA8, $1A3FF0A0, $D82C7D56, $EF903322,
    $C74E4987, $C1D138D9, $FEA2CA8C, $360BD498, $CF81F5A6, $28DE7AA5, $268EB7DA, $A4BFAD3F,
    $E49D3A2C, $0D927850, $9BCC5F6A, $62467E54, $C2138DF6, $E8B8D890, $5EF7392E, $F5AFC382,
    $BE805D9F, $7C93D069, $A92DD56F, $B31225CF, $3B99ACC8, $A77D1810, $6E639CE8, $7BBB3BDB,
    $097826CD, $F418596E, $01B79AEC, $A89A4F83, $656E95E6, $7EE6FFAA, $08CFBC21, $E6E815EF,
    $D99BE7BA, $CE366F4A, $D4099FEA, $D67CB029, $AFB2A431, $31233F2A, $3094A5C6, $C066A235,
    $37BC4E74, $A6CA82FC, $B0D090E0, $15D8A733, $4A9804F1, $F7DAEC41, $0E50CD7F, $2FF69117,
    $8DD64D76, $4DB0EF43, $544DAACC, $DF0496E4, $E3B5D19E, $1B886A4C, $B81F2CC1, $7F516546,
    $04EA5E9D, $5D358C01, $737487FA, $2E410BFB, $5A1D67B3, $52D2DB92, $335610E9, $1347D66D,
    $8C61D79A, $7A0CA137, $8E14F859, $893C13EB, $EE27A9CE, $35C961B7, $EDE51CE1, $3CB1477A,
    $59DFD29C, $3F73F255, $79CE1418, $BF37C773, $EACDF753, $5BAAFD5F, $146F3DDF, $86DB4478,
    $81F3AFCA, $3EC468B9, $2C342438, $5F40A3C2, $72C31D16, $0C25E2BC, $8B493C28, $41950DFF,
    $7101A839, $DEB30C08, $9CE4B4D8, $90C15664, $6184CB7B, $70B632D5, $745C6C48, $4257B8D0);

  DecTab2: Array[Byte] of TRijWord = (
    $A7F45150, $65417E53, $A4171AC3, $5E273A96, $6BAB3BCB, $459D1FF1, $58FAACAB, $03E34B93,
    $FA302055, $6D76ADF6, $76CC8891, $4C02F525, $D7E54FFC, $CB2AC5D7, $44352680, $A362B58F,
    $5AB1DE49, $1BBA2567, $0EEA4598, $C0FE5DE1, $752FC302, $F04C8112, $97468DA3, $F9D36BC6,
    $5F8F03E7, $9C921595, $7A6DBFEB, $595295DA, $83BED42D, $217458D3, $69E04929, $C8C98E44,
    $89C2756A, $798EF478, $3E58996B, $71B927DD, $4FE1BEB6, $AD88F017, $AC20C966, $3ACE7DB4,
    $4ADF6318, $311AE582, $33519760, $7F536245, $7764B1E0, $AE6BBB84, $A081FE1C, $2B08F994,
    $68487058, $FD458F19, $6CDE9487, $F87B52B7, $D373AB23, $024B72E2, $8F1FE357, $AB55662A,
    $28EBB207, $C2B52F03, $7BC5869A, $0837D3A5, $872830F2, $A5BF23B2, $6A0302BA, $8216ED5C,
    $1CCF8A2B, $B479A792, $F207F3F0, $E2694EA1, $F4DA65CD, $BE0506D5, $6234D11F, $FEA6C48A,
    $532E349D, $55F3A2A0, $E18A0532, $EBF6A475, $EC830B39, $EF6040AA, $9F715E06, $106EBD51,
    $8A213EF9, $06DD963D, $053EDDAE, $BDE64D46, $8D5491B5, $5DC47105, $D406046F, $155060FF,
    $FB981924, $E9BDD697, $434089CC, $9ED96777, $42E8B0BD, $8B890788, $5B19E738, $EEC879DB,
    $0A7CA147, $0F427CE9, $1E84F8C9, $00000000, $86800983, $ED2B3248, $70111EAC, $725A6C4E,
    $FF0EFDFB, $38850F56, $D5AE3D1E, $392D3627, $D90F0A64, $A65C6821, $545B9BD1, $2E36243A,
    $670A0CB1, $E757930F, $96EEB4D2, $919B1B9E, $C5C0804F, $20DC61A2, $4B775A69, $1A121C16,
    $BA93E20A, $2AA0C0E5, $E0223C43, $171B121D, $0D090E0B, $C78BF2AD, $A8B62DB9, $A91E14C8,
    $19F15785, $0775AF4C, $DD99EEBB, $607FA3FD, $2601F79F, $F5725CBC, $3B6644C5, $7EFB5B34,
    $29438B76, $C623CBDC, $FCEDB668, $F1E4B863, $DC31D7CA, $85634210, $22971340, $11C68420,
    $244A857D, $3DBBD2F8, $32F9AE11, $A129C76D, $2F9E1D4B, $30B2DCF3, $52860DEC, $E3C177D0,
    $16B32B6C, $B970A999, $489411FA, $64E94722, $8CFCA8C4, $3FF0A01A, $2C7D56D8, $903322EF,
    $4E4987C7, $D138D9C1, $A2CA8CFE, $0BD49836, $81F5A6CF, $DE7AA528, $8EB7DA26, $BFAD3FA4,
    $9D3A2CE4, $9278500D, $CC5F6A9B, $467E5462, $138DF6C2, $B8D890E8, $F7392E5E, $AFC382F5,
    $805D9FBE, $93D0697C, $2DD56FA9, $1225CFB3, $99ACC83B, $7D1810A7, $639CE86E, $BB3BDB7B,
    $7826CD09, $18596EF4, $B79AEC01, $9A4F83A8, $6E95E665, $E6FFAA7E, $CFBC2108, $E815EFE6,
    $9BE7BAD9, $366F4ACE, $099FEAD4, $7CB029D6, $B2A431AF, $233F2A31, $94A5C630, $66A235C0,
    $BC4E7437, $CA82FCA6, $D090E0B0, $D8A73315, $9804F14A, $DAEC41F7, $50CD7F0E, $F691172F,
    $D64D768D, $B0EF434D, $4DAACC54, $0496E4DF, $B5D19EE3, $886A4C1B, $1F2CC1B8, $5165467F,
    $EA5E9D04, $358C015D, $7487FA73, $410BFB2E, $1D67B35A, $D2DB9252, $5610E933, $47D66D13,
    $61D79A8C, $0CA1377A, $14F8598E, $3C13EB89, $27A9CEEE, $C961B735, $E51CE1ED, $B1477A3C,
    $DFD29C59, $73F2553F, $CE141879, $37C773BF, $CDF753EA, $AAFD5F5B, $6F3DDF14, $DB447886,
    $F3AFCA81, $C468B93E, $3424382C, $40A3C25F, $C31D1672, $25E2BC0C, $493C288B, $950DFF41,
    $01A83971, $B30C08DE, $E4B4D89C, $C1566490, $84CB7B61, $B632D570, $5C6C4874, $57B8D042);

  DecTab3: Array[Byte] of TRijWord = (
    $F45150A7, $417E5365, $171AC3A4, $273A965E, $AB3BCB6B, $9D1FF145, $FAACAB58, $E34B9303,
    $302055FA, $76ADF66D, $CC889176, $02F5254C, $E54FFCD7, $2AC5D7CB, $35268044, $62B58FA3,
    $B1DE495A, $BA25671B, $EA45980E, $FE5DE1C0, $2FC30275, $4C8112F0, $468DA397, $D36BC6F9,
    $8F03E75F, $9215959C, $6DBFEB7A, $5295DA59, $BED42D83, $7458D321, $E0492969, $C98E44C8,
    $C2756A89, $8EF47879, $58996B3E, $B927DD71, $E1BEB64F, $88F017AD, $20C966AC, $CE7DB43A,
    $DF63184A, $1AE58231, $51976033, $5362457F, $64B1E077, $6BBB84AE, $81FE1CA0, $08F9942B,
    $48705868, $458F19FD, $DE94876C, $7B52B7F8, $73AB23D3, $4B72E202, $1FE3578F, $55662AAB,
    $EBB20728, $B52F03C2, $C5869A7B, $37D3A508, $2830F287, $BF23B2A5, $0302BA6A, $16ED5C82,
    $CF8A2B1C, $79A792B4, $07F3F0F2, $694EA1E2, $DA65CDF4, $0506D5BE, $34D11F62, $A6C48AFE,
    $2E349D53, $F3A2A055, $8A0532E1, $F6A475EB, $830B39EC, $6040AAEF, $715E069F, $6EBD5110,
    $213EF98A, $DD963D06, $3EDDAE05, $E64D46BD, $5491B58D, $C471055D, $06046FD4, $5060FF15,
    $981924FB, $BDD697E9, $4089CC43, $D967779E, $E8B0BD42, $8907888B, $19E7385B, $C879DBEE,
    $7CA1470A, $427CE90F, $84F8C91E, $00000000, $80098386, $2B3248ED, $111EAC70, $5A6C4E72,
    $0EFDFBFF, $850F5638, $AE3D1ED5, $2D362739, $0F0A64D9, $5C6821A6, $5B9BD154, $36243A2E,
    $0A0CB167, $57930FE7, $EEB4D296, $9B1B9E91, $C0804FC5, $DC61A220, $775A694B, $121C161A,
    $93E20ABA, $A0C0E52A, $223C43E0, $1B121D17, $090E0B0D, $8BF2ADC7, $B62DB9A8, $1E14C8A9,
    $F1578519, $75AF4C07, $99EEBBDD, $7FA3FD60, $01F79F26, $725CBCF5, $6644C53B, $FB5B347E,
    $438B7629, $23CBDCC6, $EDB668FC, $E4B863F1, $31D7CADC, $63421085, $97134022, $C6842011,
    $4A857D24, $BBD2F83D, $F9AE1132, $29C76DA1, $9E1D4B2F, $B2DCF330, $860DEC52, $C177D0E3,
    $B32B6C16, $70A999B9, $9411FA48, $E9472264, $FCA8C48C, $F0A01A3F, $7D56D82C, $3322EF90,
    $4987C74E, $38D9C1D1, $CA8CFEA2, $D498360B, $F5A6CF81, $7AA528DE, $B7DA268E, $AD3FA4BF,
    $3A2CE49D, $78500D92, $5F6A9BCC, $7E546246, $8DF6C213, $D890E8B8, $392E5EF7, $C382F5AF,
    $5D9FBE80, $D0697C93, $D56FA92D, $25CFB312, $ACC83B99, $1810A77D, $9CE86E63, $3BDB7BBB,
    $26CD0978, $596EF418, $9AEC01B7, $4F83A89A, $95E6656E, $FFAA7EE6, $BC2108CF, $15EFE6E8,
    $E7BAD99B, $6F4ACE36, $9FEAD409, $B029D67C, $A431AFB2, $3F2A3123, $A5C63094, $A235C066,
    $4E7437BC, $82FCA6CA, $90E0B0D0, $A73315D8, $04F14A98, $EC41F7DA, $CD7F0E50, $91172FF6,
    $4D768DD6, $EF434DB0, $AACC544D, $96E4DF04, $D19EE3B5, $6A4C1B88, $2CC1B81F, $65467F51,
    $5E9D04EA, $8C015D35, $87FA7374, $0BFB2E41, $67B35A1D, $DB9252D2, $10E93356, $D66D1347,
    $D79A8C61, $A1377A0C, $F8598E14, $13EB893C, $A9CEEE27, $61B735C9, $1CE1EDE5, $477A3CB1,
    $D29C59DF, $F2553F73, $141879CE, $C773BF37, $F753EACD, $FD5F5BAA, $3DDF146F, $447886DB,
    $AFCA81F3, $68B93EC4, $24382C34, $A3C25F40, $1D1672C3, $E2BC0C25, $3C288B49, $0DFF4195,
    $A8397101, $0C08DEB3, $B4D89CE4, $566490C1, $CB7B6184, $32D570B6, $6C48745C, $B8D04257);

  DecTab4: Array[Byte] of TRijWord = (
    $5150A7F4, $7E536541, $1AC3A417, $3A965E27, $3BCB6BAB, $1FF1459D, $ACAB58FA, $4B9303E3,
    $2055FA30, $ADF66D76, $889176CC, $F5254C02, $4FFCD7E5, $C5D7CB2A, $26804435, $B58FA362,
    $DE495AB1, $25671BBA, $45980EEA, $5DE1C0FE, $C302752F, $8112F04C, $8DA39746, $6BC6F9D3,
    $03E75F8F, $15959C92, $BFEB7A6D, $95DA5952, $D42D83BE, $58D32174, $492969E0, $8E44C8C9,
    $756A89C2, $F478798E, $996B3E58, $27DD71B9, $BEB64FE1, $F017AD88, $C966AC20, $7DB43ACE,
    $63184ADF, $E582311A, $97603351, $62457F53, $B1E07764, $BB84AE6B, $FE1CA081, $F9942B08,
    $70586848, $8F19FD45, $94876CDE, $52B7F87B, $AB23D373, $72E2024B, $E3578F1F, $662AAB55,
    $B20728EB, $2F03C2B5, $869A7BC5, $D3A50837, $30F28728, $23B2A5BF, $02BA6A03, $ED5C8216,
    $8A2B1CCF, $A792B479, $F3F0F207, $4EA1E269, $65CDF4DA, $06D5BE05, $D11F6234, $C48AFEA6,
    $349D532E, $A2A055F3, $0532E18A, $A475EBF6, $0B39EC83, $40AAEF60, $5E069F71, $BD51106E,
    $3EF98A21, $963D06DD, $DDAE053E, $4D46BDE6, $91B58D54, $71055DC4, $046FD406, $60FF1550,
    $1924FB98, $D697E9BD, $89CC4340, $67779ED9, $B0BD42E8, $07888B89, $E7385B19, $79DBEEC8,
    $A1470A7C, $7CE90F42, $F8C91E84, $00000000, $09838680, $3248ED2B, $1EAC7011, $6C4E725A,
    $FDFBFF0E, $0F563885, $3D1ED5AE, $3627392D, $0A64D90F, $6821A65C, $9BD1545B, $243A2E36,
    $0CB1670A, $930FE757, $B4D296EE, $1B9E919B, $804FC5C0, $61A220DC, $5A694B77, $1C161A12,
    $E20ABA93, $C0E52AA0, $3C43E022, $121D171B, $0E0B0D09, $F2ADC78B, $2DB9A8B6, $14C8A91E,
    $578519F1, $AF4C0775, $EEBBDD99, $A3FD607F, $F79F2601, $5CBCF572, $44C53B66, $5B347EFB,
    $8B762943, $CBDCC623, $B668FCED, $B863F1E4, $D7CADC31, $42108563, $13402297, $842011C6,
    $857D244A, $D2F83DBB, $AE1132F9, $C76DA129, $1D4B2F9E, $DCF330B2, $0DEC5286, $77D0E3C1,
    $2B6C16B3, $A999B970, $11FA4894, $472264E9, $A8C48CFC, $A01A3FF0, $56D82C7D, $22EF9033,
    $87C74E49, $D9C1D138, $8CFEA2CA, $98360BD4, $A6CF81F5, $A528DE7A, $DA268EB7, $3FA4BFAD,
    $2CE49D3A, $500D9278, $6A9BCC5F, $5462467E, $F6C2138D, $90E8B8D8, $2E5EF739, $82F5AFC3,
    $9FBE805D, $697C93D0, $6FA92DD5, $CFB31225, $C83B99AC, $10A77D18, $E86E639C, $DB7BBB3B,
    $CD097826, $6EF41859, $EC01B79A, $83A89A4F, $E6656E95, $AA7EE6FF, $2108CFBC, $EFE6E815,
    $BAD99BE7, $4ACE366F, $EAD4099F, $29D67CB0, $31AFB2A4, $2A31233F, $C63094A5, $35C066A2,
    $7437BC4E, $FCA6CA82, $E0B0D090, $3315D8A7, $F14A9804, $41F7DAEC, $7F0E50CD, $172FF691,
    $768DD64D, $434DB0EF, $CC544DAA, $E4DF0496, $9EE3B5D1, $4C1B886A, $C1B81F2C, $467F5165,
    $9D04EA5E, $015D358C, $FA737487, $FB2E410B, $B35A1D67, $9252D2DB, $E9335610, $6D1347D6,
    $9A8C61D7, $377A0CA1, $598E14F8, $EB893C13, $CEEE27A9, $B735C961, $E1EDE51C, $7A3CB147,
    $9C59DFD2, $553F73F2, $1879CE14, $73BF37C7, $53EACDF7, $5F5BAAFD, $DF146F3D, $7886DB44,
    $CA81F3AF, $B93EC468, $382C3424, $C25F40A3, $1672C31D, $BC0C25E2, $288B493C, $FF41950D,
    $397101A8, $08DEB30C, $D89CE4B4, $6490C156, $7B6184CB, $D570B632, $48745C6C, $D04257B8);

  RCon: Array[1..29] of TRijWord = (
    $00000001, $00000002, $00000004, $00000008, $00000010, $00000020, $00000040, $00000080,
    $0000001B, $00000036, $0000006c, $000000d8, $000000ab, $0000004d, $0000009a, $0000002f,
    $0000005e, $000000bc, $00000063, $000000c6, $00000097, $00000035, $0000006a, $000000d4,
    $000000b3, $0000007d, $000000fa, $000000ef, $000000c5);

  InvSub: Array[Byte] of Byte = (
    $52, $09, $6A, $D5, $30, $36, $A5, $38, $BF, $40, $A3, $9E, $81, $F3, $D7, $FB,
    $7C, $E3, $39, $82, $9B, $2F, $FF, $87, $34, $8E, $43, $44, $C4, $DE, $E9, $CB,
    $54, $7B, $94, $32, $A6, $C2, $23, $3D, $EE, $4C, $95, $0B, $42, $FA, $C3, $4E,
    $08, $2E, $A1, $66, $28, $D9, $24, $B2, $76, $5B, $A2, $49, $6D, $8B, $D1, $25,
    $72, $F8, $F6, $64, $86, $68, $98, $16, $D4, $A4, $5C, $CC, $5D, $65, $B6, $92,
    $6C, $70, $48, $50, $FD, $ED, $B9, $DA, $5E, $15, $46, $57, $A7, $8D, $9D, $84,
    $90, $D8, $AB, $00, $8C, $BC, $D3, $0A, $F7, $E4, $58, $05, $B8, $B3, $45, $06,
    $D0, $2C, $1E, $8F, $CA, $3F, $0F, $02, $C1, $AF, $BD, $03, $01, $13, $8A, $6B,
    $3A, $91, $11, $41, $4F, $67, $DC, $EA, $97, $F2, $CF, $CE, $F0, $B4, $E6, $73,
    $96, $AC, $74, $22, $E7, $AD, $35, $85, $E2, $F9, $37, $E8, $1C, $75, $DF, $6E,
    $47, $F1, $1A, $71, $1D, $29, $C5, $89, $6F, $B7, $62, $0E, $AA, $18, $BE, $1B,
    $FC, $56, $3E, $4B, $C6, $D2, $79, $20, $9A, $DB, $C0, $FE, $78, $CD, $5A, $F4,
    $1F, $DD, $A8, $33, $88, $07, $C7, $31, $B1, $12, $10, $59, $27, $80, $EC, $5F,
    $60, $51, $7F, $A9, $19, $B5, $4A, $0D, $2D, $E5, $7A, $9F, $93, $C9, $9C, $EF,
    $A0, $E0, $3B, $4D, $AE, $2A, $F5, $B0, $C8, $EB, $BB, $3C, $83, $53, $99, $61,
    $17, $2B, $04, $7E, $BA, $77, $D6, $26, $E1, $69, $14, $63, $55, $21, $0C, $7D);

  ShiftRowOffsets: Array[4..8,0..3] of Integer = (
    (0,1,2,3),(0,1,2,3),(0,1,2,3),(0,1,2,4),(0,1,3,4));

//******************************************************************************

procedure TRijndaelCipher.SetKeyLength(Value: TRijLength);
begin
fKeyLength := Value;
case fKeyLength of
  rl128bit: fNk := 4;
  rl160bit: fNk := 5;
  rl192bit: fNk := 6;
  rl224bit: fNk := 7;
  rl256bit: fNk := 8;
else
  raise Exception.CreateFmt('TRijndaelCipher.SetKeyLength: Unsupported key length (%d).',[Ord(Value)]);
end;
fNr := Max(fNk,fNb) + 6;
fKeyBytes := fNk * SizeOf(TRijWord);
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.SetBlockLength(Value: TRijLength);
begin
fBlockLength := Value;
case fBlockLength of
  rl128bit: fNb := 4;
  rl160bit: fNb := 5;
  rl192bit: fNb := 6;
  rl224bit: fNb := 7;
  rl256bit: fNb := 8;
else
  raise Exception.CreateFmt('TRijndaelCipher.SetBlockLength: Unsupported block length (%d).',[Ord(Value)]);
end;
fNr := Max(fNk,fNb) + 6;
fBlockBytes := fNb * SizeOf(TRijWord);
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.CipherInit;
var
  i,j:  Integer;
  Temp: TRijWord;
begin
Move(fKey^,fRijKey,fKeyBytes);
// Rijndael initialization
For i := 0 to Pred(fNk) do
  fKeySchedule[i] := fRijKey[4*i] or (fRijKey[4*i+1] shl 8) or (fRijKey[4*i+2] shl 16) or (fRijKey[4*i+3] shl 24);
For i := fNk to Pred(fNb * (fNr + 1)) do
  begin
    Temp := fKeySchedule[i - 1];
    If (i mod fNk = 0) then
      Temp := (Byte(EncTab4[Byte(Temp shr 8)]) or
              (Byte(EncTab4[Byte(Temp shr 16)]) shl 8) or
              (Byte(EncTab4[Byte(Temp shr 24)]) shl 16) or
              (Byte(EncTab4[Byte(Temp)]) shl 24)) xor RCon[i div fNk]
    else If (fNk > 6) and (i mod fNk = 4) then
      Temp := Byte(EncTab4[Byte(Temp)]) or
             (Byte(EncTab4[Byte(Temp shr 8)]) shl 8) or
             (Byte(EncTab4[Byte(Temp shr 16)]) shl 16) or
             (Byte(EncTab4[Byte(Temp shr 24)]) shl 24);
    fKeySchedule[i] := fKeySchedule[i - fNk] xor Temp;
  end;
If fMode = cmDecrypt then
  For i := 1 to Pred(fNr) do
    For j := (i * fNb) to ((i + 1) * fNb - 1) do
      fKeySchedule[j] := DecTab1[Byte(EncTab4[Byte(fKeySchedule[j])])] xor
                         DecTab2[Byte(EncTab4[Byte(fKeySchedule[j] shr 8)])] xor
                         DecTab3[Byte(EncTab4[Byte(fKeySchedule[j] shr 16)])] xor
                         DecTab4[Byte(EncTab4[Byte(fKeySchedule[j] shr 24)])];
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.CipherFinal;
begin
// nothing to do here
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.Encrypt(const Input; out Output);
var
  i,j:        Integer;
  State:      TRijState;
  TempState:  TRijState;

  Function RoundIdx(RSize,Start,Off: Integer): Integer;
  begin
    Result := Start + Off;
    while Result >= RSize do
      Dec(Result,RSize);  
  end;

begin
For i := 0 to Pred(fNb) do
  State[i] := TRijState(Input)[i] xor fKeySchedule[i];
For j := 1 to (fNr - 1) do
  begin
    TempState := State;
    For i := 0 to Pred(fNb) do
      State[i] := EncTab1[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,0])])] xor
                  EncTab2[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,1])] shr 8)] xor
                  EncTab3[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,2])] shr 16)] xor
                  EncTab4[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,3])] shr 24)] xor
                  fKeySchedule[j * fNb + i];
  end;
For i := 0 to Pred(fNb) do
  TempState[i] := Byte(EncTab4[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,0])])]) xor
                 (Byte(EncTab4[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,1])] shr 8)]) shl 8) xor
                 (Byte(EncTab4[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,2])] shr 16)]) shl 16) xor
                 (Byte(EncTab4[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,3])] shr 24)]) shl 24) xor
                  fKeySchedule[fNr * fNb + i];
Move(TempState,Output,fBlockBytes);
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.Decrypt(const Input; out Output);
var
  i,j:        Integer;
  State:      TRijState;
  TempState:  TRijState;

  Function RoundIdx(RSize,Start,Off: Integer): Integer;
  begin
    Result := Start - Off;
    while Result < 0 do
      Inc(Result,RSize);  
  end;

begin
For i := 0 to Pred(fNb) do
  State[i] := TRijState(Input)[i] xor fKeySchedule[fNr * fNb + i];
For j := (fNr - 1) downto 1 do
  begin
    TempState := State;
    For i := 0 to Pred(fNb) do
      State[i] := DecTab1[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,0])])] xor
                  DecTab2[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,1])] shr 8)] xor
                  DecTab3[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,2])] shr 16)] xor
                  DecTab4[Byte(TempState[RoundIdx(fNb,i,ShiftRowOffsets[fNb,3])] shr 24)] xor
                  fKeySchedule[j * fNb + i];
  end;
For i := 0 to Pred(fNb) do
  TempState[i] := InvSub[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,0])])] xor
                 (InvSub[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,1])] shr 8)] shl 8) xor
                 (InvSub[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,2])] shr 16)] shl 16) xor
                 (InvSub[Byte(State[RoundIdx(fNb,i,ShiftRowOffsets[fNb,3])] shr 24)] shl 24) xor
                  fKeySchedule[i];
Move(TempState,Output,fBlockBytes);
end;

//==============================================================================

constructor TRijndaelCipher.Create(const Key; const InitVector; KeyLength, BlockLength: TRijLength; Mode: TBCMode);
begin
Create;
Init(Key,InitVector,KeyLength,BlockLength,Mode);
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

constructor TRijndaelCipher.Create(const Key; KeyLength, BlockLength: TRijLength; Mode: TBCMode);
begin
Create;
Init(Key,KeyLength,BlockLength,Mode);
end;

//------------------------------------------------------------------------------

procedure TRijndaelCipher.Init(const Key; const InitVector; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
raise Exception.Create('TRijndaelCipher.Init: Calling this method is not allowed in this class.');
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TRijndaelCipher.Init(const Key; KeyBytes, BlockBytes: TMemSize; Mode: TBCMode);
begin
raise Exception.Create('TRijndaelCipher.Init: Calling this method is not allowed in this class.');
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TRijndaelCipher.Init(const Key; const InitVector; KeyLength, BlockLength: TRijLength; Mode: TBCMode);
begin
SetKeyLength(KeyLength);
SetBlockLength(BlockLength);
inherited Init(Key,InitVector,fKeyBytes,fBlockBytes,Mode);
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TRijndaelCipher.Init(const Key; KeyLength, BlockLength: TRijLength; Mode: TBCMode);
begin
SetKeyLength(KeyLength);
SetBlockLength(BlockLength);
inherited Init(Key,fKeyBytes,fBlockBytes,Mode);
end;


end.
