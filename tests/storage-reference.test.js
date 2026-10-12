import {storageReference,parseStorageReference} from '../src/services/storage-reference.js';
const path='11111111-1111-4111-8111-111111111111/before/photo.jpg';
test('stable private references round-trip without expiry tokens',()=>{
 const value=storageReference('Cleanup Task Photos',path);
 expect(parseStorageReference(value)).toEqual({bucket:'Cleanup Task Photos',path});
 expect(value).not.toContain('?');
});
test.each(['public','sign','authenticated'])('existing %s references resolve without retaining URL credentials',kind=>{
 const value=`https://project.test/storage/v1/object/${kind}/Cleanup%20Task%20Photos/${path}?token=private`;
 expect(parseStorageReference(value,'https://project.test')).toEqual({bucket:'Cleanup Task Photos',path});
});
test.each([
 'https://foreign.test/storage/v1/object/public/Cleanup%20Task%20Photos/'+path,
 'storage://Cleanup%20Task%20Photos/'+path+'?token=private',
 'storage://avatars/user/avatar.jpg',
 'storage://Report%20Cleanup/user/before/%2e%2e',
 'storage://Report%20Cleanup/user/before/name%2fother',
 'https://project.test/other/Cleanup%20Task%20Photos/'+path,
])('untrusted or malformed reference is rejected: %s',value=>{
 expect(parseStorageReference(value,'https://project.test')).toBeNull();
});
