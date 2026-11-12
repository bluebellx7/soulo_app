import Foundation

/// JSON native messaging cannot carry Blob/ArrayBuffer values. Keep this codec
/// private to the offscreen adapter; page scripts never receive its bridge.
enum WebExtensionStructuredMessageCodec {
    static let javaScript = #"""
    (()=>{
      const limit=16*1024*1024;
      const bytesToBase64=bytes=>{let result='';for(let i=0;i<bytes.length;i+=24576)result+=btoa(String.fromCharCode(...bytes.subarray(i,i+24576)));return result;};
      const base64ToBytes=value=>{const raw=atob(value),bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);return bytes;};
      async function encode(value,seen=new WeakSet(),budget={bytes:0,nodes:0},depth=0) {
        if(depth>64 || ++budget.nodes>65536)throw Error('The offscreen message is too complex.');
        if(value===undefined)return {kind:'undefined'};
        if(typeof value==='bigint')return {kind:'bigint',value:String(value)};
        if(value===null || ['string','number','boolean'].includes(typeof value)) {
          budget.bytes+=typeof value==='string'?value.length*2:8;
          if(budget.bytes>limit)throw Error('Offscreen messages are limited to 16 MiB.');
          if(typeof value==='number'&&!Number.isFinite(value))return {kind:'number',value:String(value)};
          return {kind:'value',value};
        }
        if(typeof value!=='object')throw Error('This value cannot be sent to the offscreen document.');
        if(value instanceof Blob || value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
          const size=value instanceof Blob?value.size:value.byteLength;budget.bytes+=size;
          if(budget.bytes>limit)throw Error('Offscreen messages are limited to 16 MiB.');
          const bytes=value instanceof Blob?new Uint8Array(await value.arrayBuffer()):value instanceof ArrayBuffer?new Uint8Array(value):new Uint8Array(value.buffer,value.byteOffset,value.byteLength);
          return {kind:value instanceof Blob?'blob':value instanceof ArrayBuffer?'buffer':'view',
            value:bytesToBase64(bytes),type:value instanceof Blob?value.type:Object.prototype.toString.call(value).slice(8,-1)};
        }
        if(value instanceof Date)return {kind:'date',value:value.toISOString()};
        if(!Array.isArray(value)&&Object.prototype.toString.call(value)!=='[object Object]')
          throw Error('This structured offscreen value is unsupported.');
        if(seen.has(value))throw Error('Circular offscreen messages are unsupported.');
        seen.add(value);
        try {
          if(Array.isArray(value)){const items=[];for(const item of value)items.push(await encode(item,seen,budget,depth+1));return {kind:'array',value:items};}
          const entries=[];
          for(const key of Object.keys(value)){budget.bytes+=key.length*2;if(budget.bytes>limit)throw Error('Offscreen messages are limited to 16 MiB.');entries.push([key,await encode(value[key],seen,budget,depth+1)]);}
          return {kind:'object',value:entries};
        }finally{seen.delete(value);}
      }
      function decode(packet,depth=0) {
        if(depth>64 || !packet || typeof packet!=='object')throw Error('Invalid offscreen message.');
        switch(packet.kind) {
          case 'undefined':return undefined;
          case 'value':return packet.value;
          case 'number':return Number(packet.value);
          case 'bigint':return BigInt(packet.value);
          case 'date':return new Date(packet.value);
          case 'array':return packet.value.map(value=>decode(value,depth+1));
          case 'object':{
            const result={};
            for(const [key,value] of packet.value)Object.defineProperty(result,key,{value:decode(value,depth+1),enumerable:true,writable:true,configurable:true});
            return result;
          }
          case 'blob':case 'buffer':case 'view':{
            if(typeof packet.value!=='string'||packet.value.length>Math.ceil(limit/3)*4)throw Error('Offscreen messages are limited to 16 MiB.');
            const bytes=base64ToBytes(packet.value);
            if(packet.kind==='blob')return new Blob([bytes],{type:packet.type||''});
            if(packet.kind==='buffer')return bytes.buffer;
            const types={Uint8Array,Uint8ClampedArray,Int8Array,Uint16Array,Int16Array,Uint32Array,Int32Array,Float32Array,Float64Array,DataView};
            if(typeof BigInt64Array!=='undefined'){types.BigInt64Array=BigInt64Array;types.BigUint64Array=BigUint64Array;}
            const type=types[packet.type];if(!type)throw Error('Unsupported offscreen binary view.');return new type(bytes.buffer);
          }
          default:throw Error('Invalid offscreen message kind.');
        }
      }
      return {encode,decode};
    })()
    """#
}
