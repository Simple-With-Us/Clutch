import { afterEach, expect, it, vi } from 'vitest';
import { mkdtemp, readFile, rm, writeFile, readdir, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { Bridge, materializeAttachment, prepareAttachedPrompt } from '../src/web/chat-bridge.ts';
vi.mock('node:fs/promises', async (original) => { const actual = await original<typeof import('node:fs/promises')>(); return { ...actual, writeFile: vi.fn(actual.writeFile) }; });
const roots: string[] = [];
async function root() { const r=await mkdtemp(join(tmpdir(),'clutch-atomic-'));roots.push(r);return r; }
afterEach(async()=>{await Promise.all(roots.splice(0).map(r=>rm(r,{recursive:true,force:true})));});
const image=(data:string,name='shot.png')=>({name,mimeType:'image/png',data:Buffer.from(data).toString('base64')});
it('never overwrites an earlier image in the same session',async()=>{
 const r=await root();const first=await materializeAttachment({root:r,sessionId:'s',image:image('FIRST'),index:0});
 const second=await materializeAttachment({root:r,sessionId:'s',image:image('SECOND'),index:0});
 expect(first).not.toBe(second);expect(await readFile(first!,'utf8')).toBe('FIRST');expect(await readFile(second!,'utf8')).toBe('SECOND');
 if(process.platform!=='win32'){expect((await stat(first!)).mode&0o777).toBe(0o600);expect((await stat(dirname(first!))).mode&0o777).toBe(0o700);}
});
it('keeps duplicate names in one batch distinct with intended bytes',async()=>{
 const r=await root();const text=await prepareAttachedPrompt(r,'s','hello',[image('A'),image('B')]);
 const files=[...text.matchAll(/path="([^"]+)"/g)].map(m=>m[1]);expect(files).toHaveLength(2);expect(new Set(files).size).toBe(2);
 expect(await Promise.all(files.map(f=>readFile(f,'utf8')))).toEqual(['A','B']);
});
it('rejects complete filesystem failure instead of producing text-only prompt',async()=>{
 const r=await root();const blocked=join(r,'blocked');await writeFile(blocked,'not a directory');
 await expect(prepareAttachedPrompt(blocked,'s','hello',[image('A')])).rejects.toThrow('turn was not sent');
});
it('rejects partial failure and removes only the unused batch',async()=>{
 const r=await root();const prior=await materializeAttachment({root:r,sessionId:'s',image:image('PRIOR'),index:0});
 const actual = await vi.importActual<typeof import('node:fs/promises')>('node:fs/promises');
 vi.mocked(writeFile).mockImplementationOnce(actual.writeFile).mockRejectedValueOnce(new Error('synthetic disk failure'));
 await expect(prepareAttachedPrompt(r,'s','hello',[image('A'),image('B')])).rejects.toThrow('turn was not sent');
 expect(await readdir(join(r,'s'))).toEqual([dirname(prior!).split('/').at(-1)]);
 expect(await readFile(prior!,'utf8')).toBe('PRIOR');
});

it('never calls the model transport when attachment preparation fails', async()=>{
 const bridge=new Bridge('deepseek',{});const send=vi.fn();
 Object.defineProperty(bridge,'send',{value:send});
 await expect(bridge.prompt('invalid\0session','hello',[image('A')])).rejects.toThrow('turn was not sent');
 expect(send).not.toHaveBeenCalled();
});
