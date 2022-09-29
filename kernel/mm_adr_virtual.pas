unit mm_adr_virtual;

{$mode ObjFPC}{$H+}

interface

uses
  Windows,
  Classes,
  SysUtils,
  g23tree,
  bittype,
  sys_types;

{
 alloc/free node:
 [
  offset 12..39:28
  size   12..39:28
  free    0..0 :1
  prot    0..6 :7

  addr   12..39:28  ->[direct addr]
  reserv  0..0 :1
  direct  0..0 :1
  stack   0..0 :1
  polled  0..0 :1
  align        :4

  block  Pointer    ->[alloc bloc]
 ]

 alloc block:
 [
  offset 12..39:28
  size   12..39:28
  btype    0..7:8  = free/private/mapped/gpu

  used   12..39:28
 ]
}

const
 BT_FREE=0;
 BT_PRIV=1;
 BT_GPUM=2;
 BT_FMAP=3;

type
 PVirtualAdrBlock=^TVirtualAdrBlock;
 TVirtualAdrBlock=packed object
  private
   Function  GetOffset:QWORD;      inline;
   Procedure SetOffset(q:QWORD);   inline;
   Function  GetSize:QWORD;        inline;
   Procedure SetSize(q:QWORD);     inline;
   Function  GetUsed:QWORD;        inline;
   Procedure SetUsed(q:QWORD);     inline;
  public
   F:bitpacked record
    Offset:bit28;
    Size  :bit28;
    btype :bit8;
    used  :DWORD;
   end;
  property  Offset:QWORD   read GetOffset write SetOffset;
  property  Size:QWORD     read GetSize   write SetSize;
  property  Used:QWORD     read GetUsed   write SetUsed;
  function  Commit(_offset,_size:QWORD;prot:Integer):Integer;
  function  Free(_offset,_size:QWORD):Integer;
 end;

 TVirtualAdrNode=packed object
  private
   //free:  [Size]  |[Offset]
   //alloc: [Offset]
   Function  GetOffset:QWORD;      inline;
   Procedure SetOffset(q:QWORD);   inline;
   Function  GetSize:QWORD;        inline;
   Procedure SetSize(q:QWORD);     inline;
   Function  GetAddr:Pointer;      inline;
   Procedure SetAddr(p:Pointer);   inline;
   Function  GetIsFree:Boolean;    inline;
   Procedure SetIsFree(b:Boolean); inline;
  public
   F:bitpacked record
    Offset:bit28;
    Size  :bit28;
    Free  :bit1;
    prot  :bit7;
    addr  :bit28;
    reserv:bit1;
    direct:bit1;
    stack :bit1;
    polled:bit1;
    align :bit4;
   end;
   block:PVirtualAdrBlock;
   property Offset:QWORD   read GetOffset write SetOffset;
   property Size:QWORD     read GetSize   write SetSize;
   property addr:Pointer   read GetAddr   write SetAddr;
   property IsFree:Boolean read GetIsFree write SetIsFree;
   Function cmp_merge(const n:TVirtualAdrNode):Boolean;
 end;

type
 TVirtualAdrFreeCompare=object
  function c(const a,b:TVirtualAdrNode):Integer; static;
 end;
 TVirtualAdrAllcCompare=object
  function c(const a,b:TVirtualAdrNode):Integer; static;
 end;

 TVirtualManager=class
  private
   type
    TFreePoolNodeSet=specialize T23treeSet<TVirtualAdrNode,TVirtualAdrFreeCompare>;
    TAllcPoolNodeSet=specialize T23treeSet<TVirtualAdrNode,TVirtualAdrAllcCompare>;

   var
    Flo,Fhi:QWORD;

    FFreeSet:TFreePoolNodeSet;
    FAllcSet:TAllcPoolNodeSet;
  public
    property lo:QWORD read Flo;
    property hi:QWORD read Fhi;

    Constructor Create(_lo,_hi:QWORD);
  private
    procedure _Insert(const key:TVirtualAdrNode);
    Function  _FetchFree_s(ss,Size,Align:QWORD;var R:TVirtualAdrNode):Boolean;
    Function  _FetchNode_m(mode:Byte;cmp:QWORD;var R:TVirtualAdrNode):Boolean;
    Function  _Find_m(mode:Byte;var R:TVirtualAdrNode):Boolean;

    procedure _Merge(key:TVirtualAdrNode);
    procedure _Devide(Offset,Size:QWORD;var key:TVirtualAdrNode);
  public
    Function  Alloc_flex(ss,Size,Align:QWORD;prot:Byte;var AdrOut:QWORD):Integer;
    Function  check_fixed(Offset,Size:QWORD;btype,flags:Byte):Integer;
    Function  mmap_flex(Offset,Size:QWORD;prot,flags:Byte):Integer;
    Function  CheckedAlloc(Offset,Size:QWORD):Integer;
    Function  CheckedMMap(Offset,Size:QWORD):Integer;
    Function  Release(Offset,Size:QWORD):Integer;
    //Function  mmap(Offset,Size:QWORD;addr:Pointer):Integer;
    Function  mmap2(Offset,Size:QWORD;addr:Pointer;mtype:Byte):Integer;

    procedure Print;
 end;

implementation

uses
 mmap;

const
 ENOENT= 2;
 ENOMEM=12;
 EACCES=13;
 EBUSY =16;
 EINVAL=22;
 ENOSYS=78;

//

function NewAdrBlock(Offset,Size:QWORD;prot:Integer;btype:Byte;fd:Integer;offst:size_t):PVirtualAdrBlock;
var
 FShift :QWORD;
 FOffset:QWORD;
 FSize  :QWORD;
 err    :Integer;
begin
 Result:=nil;

 FOffset:=AlignDw(Offset,GRANULAR_PAGE_SIZE);
 FShift :=Offset-FOffset;
 FSize  :=AlignUp(FShift+Size,GRANULAR_PAGE_SIZE);

 case btype of
  BT_PRIV,
  BT_GPUM:
   begin
    err:=_VirtualReserve(Pointer(FOffset),FSize,prot);
    if (err<>0) then Exit;
   end;
  BT_FMAP:
   begin
    if (offst<FShift) then Exit;
    err:=_VirtualMmap(Pointer(FOffset),FSize,prot,fd,offst-FShift);
    if (err<>0) then Exit;
   end;
  else
       Exit;
 end;

 Result:=AllocMem(SizeOf(TVirtualAdrBlock));
 if (Result=nil) then Exit;

 Result^.F.btype :=btype;
 Result^.Offset  :=FOffset;
 Result^.Size    :=FSize;
end;

//

function TVirtualAdrFreeCompare.c(const a,b:TVirtualAdrNode):Integer;
begin
 //1 FSize
 Result:=Integer(a.F.Size>b.F.Size)-Integer(a.F.Size<b.F.Size);
 if (Result<>0) then Exit;
 //2 FOffset
 Result:=Integer(a.F.Offset>b.F.Offset)-Integer(a.F.Offset<b.F.Offset);
end;

function TVirtualAdrAllcCompare.c(const a,b:TVirtualAdrNode):Integer;
begin
 //1 FOffset
 Result:=Integer(a.F.Offset>b.F.Offset)-Integer(a.F.Offset<b.F.Offset);
end;

//

Function TVirtualAdrBlock.GetOffset:QWORD; inline;
begin
 Result:=QWORD(F.Offset) shl 12;
end;

Procedure TVirtualAdrBlock.SetOffset(q:QWORD); inline;
begin
 F.Offset:=DWORD(q shr 12);
 Assert(GetOffset=q);
end;

Function TVirtualAdrBlock.GetSize:QWORD; inline;
begin
 Result:=QWORD(F.Size) shl 12;
end;

Procedure TVirtualAdrBlock.SetSize(q:QWORD); inline;
begin
 F.Size:=DWORD(q shr 12);
 Assert(GetSize=q);
end;

Function TVirtualAdrBlock.GetUsed:QWORD; inline;
begin
 Result:=QWORD(F.used) shl 12;
end;

Procedure TVirtualAdrBlock.SetUsed(q:QWORD); inline;
begin
 F.used:=DWORD(q shr 12);
 Assert(GetUsed=q);
end;

function TVirtualAdrBlock.Commit(_offset,_size:QWORD;prot:Integer):Integer;
begin
 Result:=0;
 Assert((Used+_size)<=Size);
 Used:=Used+_size;

 case F.btype of
  BT_PRIV,
  BT_GPUM:
   begin
    Result:=_VirtualCommit(Pointer(_offset),_size,prot);
   end;
  else;
 end;
end;

function TVirtualAdrBlock.Free(_offset,_size:QWORD):Integer;
begin
 Assert(Used>=_size);
 Used:=Used-_size;
 Result:=_VirtualDecommit(Pointer(_offset),_size);
end;

//

Function TVirtualAdrNode.GetOffset:QWORD; inline;
begin
 Result:=QWORD(F.Offset) shl 12;
end;

Procedure TVirtualAdrNode.SetOffset(q:QWORD); inline;
begin
 F.Offset:=DWORD(q shr 12);
 Assert(GetOffset=q);
end;

Function TVirtualAdrNode.GetSize:QWORD; inline;
begin
 Result:=QWORD(F.Size) shl 12;
end;

Procedure TVirtualAdrNode.SetSize(q:QWORD); inline;
begin
 F.Size:=DWORD(q shr 12);
 Assert(GetSize=q);
end;

Function TVirtualAdrNode.GetAddr:Pointer; inline;
begin
 Result:=Pointer(QWORD(F.addr) shl 12);
end;

Procedure TVirtualAdrNode.SetAddr(p:Pointer); inline;
begin
 F.addr:=DWORD(QWORD(p) shr 12);
 Assert(GetAddr=p);
end;

Function TVirtualAdrNode.GetIsFree:Boolean; inline;
begin
 Result:=Boolean(F.Free);
end;

Procedure TVirtualAdrNode.SetIsFree(b:Boolean); inline;
begin
 F.Free:=Byte(b);
end;

Function TVirtualAdrNode.cmp_merge(const n:TVirtualAdrNode):Boolean;
begin
 Result:=False;
 if (F.prot  <>n.F.prot  ) then Exit;
 if (F.reserv<>n.F.reserv) then Exit;
 if (F.direct<>n.F.direct) then Exit;
 if (F.stack <>n.F.stack ) then Exit;
 if (F.polled<>n.F.polled) then Exit;
 if (block   <>n.block   ) then Exit;
 Result:=True;
end;

///

Constructor TVirtualManager.Create(_lo,_hi:QWORD);
var
 key:TVirtualAdrNode;
begin
 Assert(_lo<_hi);

 Flo:=_lo;
 Fhi:=_hi;

 key:=Default(TVirtualAdrNode);
 key.IsFree:=True;
 key.Offset:=_lo;
 key.Size  :=(_hi-_lo+1);

 _Insert(key);
end;

procedure TVirtualManager._Insert(const key:TVirtualAdrNode);
begin
 if key.IsFree then
 begin
  if (key.block=nil) then
  begin
   FFreeSet.Insert(key);
  end else
  begin
   case key.block^.F.btype of
    BT_PRIV,
    BT_GPUM:FFreeSet.Insert(key);
    else;
   end;
  end;
 end;
 FAllcSet.Insert(key);
end;

//free:  [Size]  |[Offset]
Function TVirtualManager._FetchFree_s(ss,Size,Align:QWORD;var R:TVirtualAdrNode):Boolean;
var
 It:TFreePoolNodeSet.Iterator;
 key:TVirtualAdrNode;
 Offset:QWORD;
begin
 Result:=false;
 key:=Default(TVirtualAdrNode);
 key.Offset:=ss;
 key.Size  :=Size;
 It:=FFreeSet.find_be(key);
 if (It.Item=nil) then Exit;
 repeat
  key:=It.Item^;
  Offset:=System.Align(key.Offset,Align);
  if (Offset+Size)<=(key.Offset+key.Size) then
  begin
   R:=key;
   FAllcSet.delete(key);
   FFreeSet.erase(It);
   Exit(True);
  end;
 until not It.Next;
end;

function ia(addr:Pointer;Size:qword):Pointer; inline;
begin
 if (addr=nil) then
 begin
  Result:=nil;
 end else
 begin
  Result:=addr+Size;
 end;
end;

const
 M_LE=0;
 M_BE=1;

 C_UP=2;
 C_DW=4;

 C_LE=6;
 C_BE=8;

Function TVirtualManager._FetchNode_m(mode:Byte;cmp:QWORD;var R:TVirtualAdrNode):Boolean;
var
 It:TAllcPoolNodeSet.Iterator;
 key,rkey:TVirtualAdrNode;
begin
 Result:=false;

 key:=R;

 Case (mode and 1) of
  M_LE:It:=FAllcSet.find_le(key);
  M_BE:It:=FAllcSet.find_be(key);
  else
       Exit;
 end;

 if (It.Item=nil) then Exit;

 rkey:=It.Item^;

 if (rkey.IsFree <>key.IsFree ) then Exit;

 Case (mode and (not 1)) of
  C_UP:
       begin
        if not rkey.cmp_merge(key)             then Exit;
        if (ia(rkey.addr,rkey.Size)<>key.addr) then Exit;
        if ((rkey.Offset+rkey.Size)<>cmp     ) then Exit;
       end;
  C_DW:
       begin
        if not rkey.cmp_merge(key)  then Exit;
        if (rkey.addr   <>key.addr) then Exit;
        if (rkey.Offset <>cmp     ) then Exit;
       end;

  C_LE:if ((rkey.Offset+rkey.Size)<cmp) then Exit;
  C_BE:if (key.Offset<cmp) then Exit;

  else
       Exit;
 end;

 R:=rkey;
 FAllcSet.erase(It);
 FFreeSet.delete(rkey);
 Result:=True;
end;

Function TVirtualManager._Find_m(mode:Byte;var R:TVirtualAdrNode):Boolean;
var
 It:TAllcPoolNodeSet.Iterator;
begin
 Result:=false;

 Case mode of
  M_LE:It:=FAllcSet.find_le(R);
  M_BE:It:=FAllcSet.find_be(R);
  else
       Exit;
 end;

 if (It.Item=nil) then Exit;
 R:=It.Item^;
 Result:=True;
end;

//

procedure TVirtualManager._Merge(key:TVirtualAdrNode);
var
 rkey:TVirtualAdrNode;
begin

 //prev union
 repeat
  rkey:=key;
  rkey.F.Offset:=rkey.F.Offset-1; //hack
  rkey.addr    :=key.addr;        //find addr

  if not _FetchNode_m(M_LE or C_UP,key.Offset,rkey) then Break;

  key.F.Size  :=key.F.Size+(key.F.Offset-rkey.F.Offset); //hack
  key.F.Offset:=rkey.F.Offset;                           //hack
  key.addr    :=rkey.addr;                               //prev addr
 until false;

 //next union
 repeat
  rkey:=key;
  rkey.F.Offset:=rkey.F.Offset+rkey.F.Size; //hack
  rkey.addr    :=ia(key.addr,key.Size);     //find addr

  if not _FetchNode_m(M_BE or C_DW,(key.Offset+key.Size),rkey) then Break;

  key.F.Size  :=key.F.Size+rkey.F.Size; //hack
 until false;

 _Insert(key);
end;

procedure TVirtualManager._Devide(Offset,Size:QWORD;var key:TVirtualAdrNode);
var
 FOffset:QWORD;
 FSize:QWORD;
 Faddr:Pointer;
 FEndN,FEndO:QWORD;
begin
 FOffset:=key.Offset;
 FSize  :=key.Size;
 Faddr  :=key.addr;

 FEndN:=Offset +Size;
 FEndO:=FOffset+FSize;

 if (Offset>FOffset) then //prev save
 begin
  key.Size:=Offset-FOffset;
  _Merge(key);
 end;

 if (FEndO>FEndN) then //next save
 begin
  key.Offset:=FEndN;
  key.Size  :=FEndO-FEndN;
  key.addr  :=ia(Faddr,(FEndN-FOffset));

  _Merge(key);
 end else
 if (FEndO<>FEndN) then //tunc size
 begin
  Size:=FEndO-Offset;
 end;

 //new save
 key.Offset :=Offset;
 key.Size   :=Size;
 key.addr   :=ia(Faddr,(Offset-FOffset));
end;

Function TVirtualManager.Alloc_flex(ss,Size,Align:QWORD;prot:Byte;var AdrOut:QWORD):Integer;
var
 key:TVirtualAdrNode;
 Offset:QWORD;
 block:PVirtualAdrBlock;
begin
 Result:=0;
 if (Size=0) or (Align=0) then Exit(EINVAL);
 if (ss<Flo) or (ss>Fhi)  then Exit(EINVAL);

 key:=Default(TVirtualAdrNode);

 if _FetchFree_s(ss,Size,Align,key) then
 begin
  Offset:=System.Align(key.Offset,Align);

  _Devide(Offset,Size,key);

  if (key.block<>nil) then
  begin
   block:=key.block;
   Case block^.F.btype of
    BT_FMAP:
     begin
      _Insert(key); //ret
      Assert(false,'map flex to file');
      Exit(ENOSYS);
     end;
    else;
   end;
  end else
  begin
   block:=NewAdrBlock(key.Offset,key.Size,prot,BT_PRIV,-1,0);
   if (block=nil) then
   begin
    _Merge(key); //ret
    Assert(False);
    Exit(ENOSYS);
   end;
  end;

  block^.Commit(key.Offset,key.Size,prot);
  if _isgpu(prot) then //mark to gpu
  begin
   block^.F.btype:=BT_GPUM;
  end;

  //new save
  key.IsFree  :=False;
  key.F.prot  :=prot;
  key.F.addr  :=0;
  key.F.reserv:=0;
  key.F.direct:=0;
  key.F.stack :=0;
  key.F.polled:=0;
  key.block   :=block;
  _Merge(key);

  AdrOut:=key.Offset;
  Result:=0;
 end else
 begin
  Result:=ENOMEM;
 end;
end;

Function TVirtualManager.check_fixed(Offset,Size:QWORD;btype,flags:Byte):Integer;
var
 It:TAllcPoolNodeSet.Iterator;
 key:TVirtualAdrNode;
 FEndO:QWORD;
begin
 Result:=0;
 if (Size=0) then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 FEndO:=Offset+Size;

 key:=Default(TVirtualAdrNode);
 key.Offset:=Offset;

 It:=FAllcSet.find_le(key);
 While (It.Item<>nil) do
 begin
  key:=It.Item^;

  if (Offset>=key.Offset) then
  begin
   if key.IsFree then
   begin
    if (key.block<>nil) then
    begin
     Case btype of
      BT_PRIV,
      BT_GPUM:
       begin
        Case key.block^.F.btype of
         BT_PRIV,
         BT_GPUM:;
         else
          Exit(ENOSYS); //file map not valid for any devide
        end;
       end;
      else
       Exit(ENOSYS);
     end;
    end;
   end else
   begin
    if (flags and MAP_NO_OVERWRITE)<>0 then
    begin
     Exit(ENOMEM);
    end;
   end;
  end;

  if (key.Offset>=FEndO) then Break;

  It.Next;
 end;
end;

Function TVirtualManager.mmap_flex(Offset,Size:QWORD;prot,flags:Byte):Integer;
var
 key:TVirtualAdrNode;
 FEndN,FEndO:QWORD;
 FSize:QWORD;
 btype:Byte;
begin
 Result:=0;
 if (Size=0)                     then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 if _isgpu(prot) then
 begin
  btype:=BT_GPUM;
 end else
 begin
  btype:=BT_PRIV;
 end;

 Result:=check_fixed(Offset,Size,btype,flags);
 if (Result<>0) then Exit;

 repeat

  key:=Default(TVirtualAdrNode);
  key.IsFree:=False;
  key.Offset:=Offset;

  if _FetchNode_m(M_LE or C_LE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(Offset,Size,key);

   if (key.block=nil) then
   begin
    key.block:=NewAdrBlock(key.Offset,key.Size,prot,btype,-1,0);
    if (key.block=nil) then
    begin
     _Merge(key); //ret
     Assert(False);
     Exit(ENOSYS);
    end;
   end;

   key.block^.Commit(key.Offset,key.Size,prot);

   //new save
   key.IsFree  :=False;
   key.F.prot  :=prot;
   key.F.addr  :=0;
   key.F.reserv:=0;
   key.F.direct:=0;
   key.F.stack :=0;
   key.F.polled:=0;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   //addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _FetchNode_m(M_BE or C_BE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(key.Offset,FEndN-key.Offset,key);

   //new save
   key.IsFree :=False;
   //key.addr   :=addr;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   //addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_LE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   //addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_BE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   //addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  begin
   Break;
  end;

 until false;
end;

Function TVirtualManager.CheckedAlloc(Offset,Size:QWORD):Integer;
var
 It:TAllcPoolNodeSet.Iterator;
 key:TVirtualAdrNode;
 FEndO:QWORD;
begin
 Result:=0;
 if (Size=0) then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 FEndO:=Offset+Size;

 key:=Default(TVirtualAdrNode);
 key.Offset:=Offset;

 It:=FAllcSet.find_le(key);
 While (It.Item<>nil) do
 begin
  key:=It.Item^;

  if (Offset>=key.Offset) then
  begin
   if not key.IsFree then
   begin
    Exit(ENOMEM);
   end;
  end;

  if (key.Offset>=FEndO) then Break;

  It.Next;
 end;
end;

Function TVirtualManager.CheckedMMap(Offset,Size:QWORD):Integer;
var
 It:TAllcPoolNodeSet.Iterator;
 key:TVirtualAdrNode;
 FEndO:QWORD;
begin
 Result:=0;
 if (Size=0) then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 FEndO:=Offset+Size;

 key:=Default(TVirtualAdrNode);
 key.Offset:=Offset;

 It:=FAllcSet.find_le(key);
 While (It.Item<>nil) do
 begin
  key:=It.Item^;

  if (Offset>=key.Offset) then
  begin
   if key.IsFree then
   begin
    Exit(EACCES);
   end;
   if (key.addr<>nil) then
   begin
    Exit(EBUSY);
   end;
  end;

  if (key.Offset>=FEndO) then Break;

  It.Next;
 end;
end;

Function TVirtualManager.Release(Offset,Size:QWORD):Integer;
var
 key:TVirtualAdrNode;
 FEndN,FEndO:QWORD;
 FSize:QWORD;
begin
 Result:=0;
 if (Size=0) then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 repeat

  key:=Default(TVirtualAdrNode);
  key.IsFree:=False;
  key.Offset:=Offset;

  if _FetchNode_m(M_LE or C_LE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(Offset,Size,key);

   //new save
   key.IsFree :=True;
   key.F.prot :=0;
   //key.F.ntype:=NT_FREE;
   key.addr   :=nil;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _FetchNode_m(M_BE or C_BE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(key.Offset,FEndN-key.Offset,key);

   //new save
   key.IsFree :=True;
   key.F.prot :=0;
   //key.F.ntype:=NT_FREE;
   key.addr   :=nil;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_LE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_BE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  begin
   Break;
  end;

 until false;
end;

Function TVirtualManager.mmap2(Offset,Size:QWORD;addr:Pointer;mtype:Byte):Integer;
var
 key:TVirtualAdrNode;
 FEndN,FEndO:QWORD;
 FSize:QWORD;
begin
 Result:=0;
 if (Size=0)                     then Exit(EINVAL);
 if (Offset<Flo) or (Offset>Fhi) then Exit(EINVAL);

 repeat

  key:=Default(TVirtualAdrNode);
  key.IsFree:=False;
  key.Offset:=Offset;

  if _FetchNode_m(M_LE or C_LE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(Offset,Size,key);

   //new save
   key.IsFree :=False;
   //key.F.mtype:=mtype;
   key.addr   :=addr;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _FetchNode_m(M_BE or C_BE,Offset,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   _Devide(key.Offset,FEndN-key.Offset,key);

   //new save
   key.IsFree :=False;
   //key.F.mtype:=mtype;
   key.addr   :=addr;
   _Merge(key);

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_LE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  if _Find_m(M_BE,key) then
  begin
   FEndN:=Offset+Size;
   FEndO:=key.Offset+key.Size;

   if (FEndO>=FEndN) then Break;

   FSize:=FEndO-Offset;

   addr  :=ia(addr,FSize);
   Offset:=Offset+FSize;
   Size  :=Size  -FSize;
  end else
  begin
   Break;
  end;

 until false;
end;

function _alloc_str(IsFree:Boolean):RawByteString;
begin
 Case IsFree of
  True :Result:='FREE';
  FAlse:Result:='ALLC';
 end;
end;

procedure TVirtualManager.Print;
var
 key:TVirtualAdrNode;
 It:TAllcPoolNodeSet.Iterator;
begin
 It:=FAllcSet.cbegin;
 While (It.Item<>nil) do
 begin
  key:=It.Item^;

  Writeln(HexStr(key.Offset,10),'..',
          HexStr(key.Offset+key.Size,10),':',
          HexStr(key.Size,10),'#',
          HexStr(qword(key.addr),10),'#',
          _alloc_str(key.IsFree),'#');

  It.Next;
 end;
end;

procedure itest;
var
 test:TVirtualManager;
 addr:array[0..5] of qword;
begin
 test:=TVirtualManager.Create(0,$180000000-1);


end;

initialization
 //itest;

end.



