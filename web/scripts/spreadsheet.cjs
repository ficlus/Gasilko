// Untrusted workbooks are parsed in a disposable, credential-free process.
const XLSX = require('xlsx');
const {inflateRawSync} = require('node:zlib');
const MAX_ROWS=10001, MAX_COLS=64, MAX_CELL=4096, EXPANDED=64*1024*1024;
function fail(code='INVALID_FILE'){throw new Error(code);}
function zipGuard(b){
 let e=-1;for(let p=b.length-22;p>=Math.max(0,b.length-65557);p--)if(b.readUInt32LE(p)===0x06054b50){e=p;break;}
 if(e<0||b.readUInt16LE(e+4)||b.readUInt16LE(e+6))fail();
 const count=b.readUInt16LE(e+10);if(count>1000||count===65535)fail('LIMIT_EXCEEDED');
 let p=b.readUInt32LE(e+16),total=0,workbook=false;const names=new Set();
 for(let i=0;i<count;i++){
  if(p+46>b.length||b.readUInt32LE(p)!==0x02014b50)fail();
  const flags=b.readUInt16LE(p+8),method=b.readUInt16LE(p+10),size=b.readUInt32LE(p+20),expanded=b.readUInt32LE(p+24);
  const n=b.readUInt16LE(p+28),extra=b.readUInt16LE(p+30),comment=b.readUInt16LE(p+32),offset=b.readUInt32LE(p+42);
  const name=b.subarray(p+46,p+46+n).toString('utf8');
  if(flags&1||!['0','8'].includes(String(method))||expanded>EXPANDED||size>b.length||names.has(name)||name.includes('..')||name.startsWith('/'))fail();
  names.add(name);if(/vbaProject|macrosheet|encrypted/i.test(name))fail();if(name==='xl/workbook.xml')workbook=true;
  if(offset+30>b.length||b.readUInt32LE(offset)!==0x04034b50)fail();
  const start=offset+30+b.readUInt16LE(offset+26)+b.readUInt16LE(offset+28);if(start+size>b.length)fail();
  const value=method===8?inflateRawSync(b.subarray(start,start+size),{maxOutputLength:EXPANDED-total+1}):b.subarray(start,start+size);
  total+=value.length;if(value.length!==expanded||total>EXPANDED)fail('LIMIT_EXCEEDED');
  if(name==='[Content_Types].xml'&&/macroEnabled/i.test(value.toString('utf8')))fail();
  p+=46+n+extra+comment;
 }
 if(!workbook)fail();
}
function xlsGuard(b){
 if(b.subarray(0,8).toString('hex')!=='d0cf11e0a1b11ae1')fail();
 const cfb=XLSX.CFB.read(b,{type:'buffer'});
 if(cfb.FileIndex.length>1000)fail('LIMIT_EXCEEDED');
 if(cfb.FileIndex.some(e=>/EncryptedPackage|EncryptionInfo/i.test(e.name)))fail('ENCRYPTED_FILE');
 const stream=cfb.FileIndex.find(e=>/^(Workbook|Book)$/i.test(e.name));if(!stream)fail();
 const bytes=Buffer.from(stream.content);if(bytes.length>EXPANDED)fail('LIMIT_EXCEEDED');
 for(let p=0;p+4<=bytes.length;){const id=bytes.readUInt16LE(p),n=bytes.readUInt16LE(p+2);if(id===0x002f)fail('ENCRYPTED_FILE');p+=4+n;if(p>bytes.length)fail();}
}
function csv(text,delimiter){
 const rows=[];let row=[],cell='',quoted=false,closed=false;
 const push=()=>{if(cell.length>MAX_CELL)fail('LIMIT_EXCEEDED');row.push(cell);cell='';closed=false;if(row.length>MAX_COLS)fail('LIMIT_EXCEEDED');};
 const line=()=>{push();rows.push(row);row=[];if(rows.length>MAX_ROWS)fail('LIMIT_EXCEEDED');};
 for(let i=0;i<text.length;i++){const c=text[i];
  if(quoted){if(c==='"'){if(text[i+1]==='"'){cell+='"';i++;}else{quoted=false;closed=true;}}else cell+=c;}
  else if(c===delimiter)push();else if(c==='\n'||c==='\r'){line();if(c==='\r'&&text[i+1]==='\n')i++;}
  else if(c==='"'&&!cell&&!closed)quoted=true;else {if(closed||c==='"')fail('INVALID_CSV');cell+=c;}
  if(cell.length>MAX_CELL)fail('LIMIT_EXCEEDED');
 }
 if(quoted)fail('INVALID_CSV');if(cell||row.length||closed)line();return rows;
}
function parse(m){
 const b=Buffer.from(m.bytes,'base64');if(b.length>10*1024*1024)fail('LIMIT_EXCEEDED');
 if(m.format==='csv'){
  const text=new TextDecoder('utf-8',{fatal:true}).decode(b).replace(/^\uFEFF/,'');if(text.includes('\0'))fail();
  let delimiter=m.delimiter;if(![',',';','\t'].includes(delimiter)){
   const candidates=[',',';','\t'].flatMap(d=>{try{const r=csv(text,d);return r.length&&r[0].length>1&&r.every(x=>x.length===r[0].length||x.every(c=>!c))?[d]:[];}catch{return [];}});
   if(candidates.length!==1)fail('DELIMITER_REQUIRED');delimiter=candidates[0];
  }
  const rows=csv(text,delimiter);return {sheets:['CSV'],sheet:'CSV',delimiter,rows};
 }
 if(m.format==='xlsx')zipGuard(b);else if(m.format==='xls')xlsGuard(b);else fail();
 const options={type:'buffer',cellHTML:false,cellStyles:false,bookVBA:false,bookDeps:false,cellFormula:true,cellDates:false};
 const names=XLSX.read(b,{...options,bookSheets:true}).SheetNames;if(names.length>16)fail('LIMIT_EXCEEDED');
 const sheet=m.sheet||(names.length===1?names[0]:null);if(!sheet)return {sheets:names,rows:null};if(!names.includes(sheet))fail();
 const wb=XLSX.read(b,{...options,sheets:sheet,nodim:true,sheetRows:MAX_ROWS+1});const ws=wb.Sheets[sheet];
 const range=XLSX.utils.decode_range(ws['!fullref']||ws['!ref']||'A1');if(range.e.r>=MAX_ROWS||range.e.c>=MAX_COLS)fail('LIMIT_EXCEEDED');
 const rows=[];
 for(let r=0;r<=range.e.r;r++){const row=[];for(let c=0;c<=range.e.c;c++){
  const cell=ws[XLSX.utils.encode_cell({r,c})];if(cell?.t==='e'||(cell?.f&&cell.v==null))fail('FORMULA_VALUE_MISSING');
  const v=cell?.v??'';if(!['string','number','boolean'].includes(typeof v)||String(v).length>MAX_CELL||typeof v==='number'&&!Number.isFinite(v))fail('INVALID_CELL');row.push(v);
 }rows.push(row);}return {sheets:names,sheet,rows};
}
function write(m){
 const wb=XLSX.utils.book_new();for(const s of m.sheets){
  const ws=XLSX.utils.aoa_to_sheet(s.rows);if(s.rows.length){ws['!autofilter']={ref:XLSX.utils.encode_range({s:{r:0,c:0},e:{r:s.rows.length-1,c:Math.max(0,s.rows[0].length-1)}})};}
  ws['!cols']=(s.rows[0]||[]).map(()=>({wch:24}));XLSX.utils.book_append_sheet(wb,ws,s.name);
 }
 const b=XLSX.write(wb,{type:'buffer',bookType:'xlsx',compression:true});if(b.length>32*1024*1024)fail('LIMIT_EXCEEDED');return {bytes:b.toString('base64')};
}
process.once('message',m=>{try{const result=m.action==='write'?write(m):parse(m);if(Buffer.byteLength(JSON.stringify(result))>48*1024*1024)fail('LIMIT_EXCEEDED');process.send({result},()=>process.exit(0));}
 catch(e){const safe=['LIMIT_EXCEEDED','DELIMITER_REQUIRED','ENCRYPTED_FILE','INVALID_CSV','FORMULA_VALUE_MISSING','INVALID_CELL'];process.send({error:safe.includes(e.message)?e.message:'INVALID_FILE'},()=>process.exit(0));}});
