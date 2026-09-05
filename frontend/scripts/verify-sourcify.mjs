/** Public source verification through Sourcify v2 (v1 was retired July 2026).
 * Usage: node verify-sourcify.mjs MANIFEST BUILD_INFO_DIR OUTPUT
 * No signing key or private RPC is sent to the verifier. */
import fs from 'node:fs'
import path from 'node:path'
const [manifestPath, buildDirectory, outputPath] = process.argv.slice(2)
const manifest = JSON.parse(fs.readFileSync(manifestPath))
if (manifest.chainId !== 84532) throw Error('This release verifier is Base Sepolia only.')
const contracts = {
  factory:'src/PSPFactory.sol:PSPFactory', token:'src/PSPToken.sol:PSPToken',
  controller:'src/RoundController.sol:RoundController', hook:'src/CurveHook.sol:CurveHook',
  staker:'src/PSPStaker.sol:PSPStaker', mix:'src/testnet/SepoliaMixETH.sol:SepoliaMixETH',
  registry:'src/PSPReferralRegistry.sol:PSPReferralRegistry',
  zapIn:'src/PSPZapIn.sol:PSPZapIn', zapOut:'src/PSPZapOut.sol:PSPZapOut',
  faucet:'src/testnet/MixETHFaucet.sol:MixETHFaucet', reinvestor:'src/PSPReinvestor.sol:PSPReinvestor',
  descriptor:'src/PepeDescriptor.sol:PepeDescriptor', hookDeployer:'src/HookDeployer.sol:HookDeployer',
  controllerDeployer:'src/ControllerDeployer.sol:ControllerDeployer', stakerDeployer:'src/StakerDeployer.sol:StakerDeployer',
  tokenDeployer:'src/TokenDeployer.sol:TokenDeployer',
}
const builds = fs.readdirSync(buildDirectory).filter(f=>f.endsWith('.json')).map(f=>JSON.parse(fs.readFileSync(path.join(buildDirectory,f))))
const base = 'https://sourcify.dev/server/v2'
const record = fs.existsSync(outputPath) ? JSON.parse(fs.readFileSync(outputPath)) : { chainId:84532, revision:manifest.revision, contracts:{} }
const save=()=>{fs.mkdirSync(path.dirname(outputPath),{recursive:true});fs.writeFileSync(outputPath,JSON.stringify(record,null,2)+'\n')}
const request = async (url, options={}) => {
  const response=await fetch(url,{...options,signal:AbortSignal.timeout(60_000)})
  const body=await response.json()
  if(!response.ok)throw Error(`${response.status}: ${body.message??JSON.stringify(body)}`)
  return body
}
for (const [name,identifier] of Object.entries(contracts)) {
  const address=manifest.addresses[name]
  if(!address)continue
  const [source,contract]=identifier.split(':')
  const build=builds.find(b=>b.input?.sources[source]&&b.output?.contracts?.[source]?.[contract])
  if(!build)throw Error(`No exact build input for ${identifier}`)
  const previous=record.contracts[name]
  if(previous?.address===address && previous?.runtimeMatch==='exact_match')continue
  try {
    const body={stdJsonInput:build.input,compilerVersion:build.solcLongVersion,contractIdentifier:identifier}
    const job=await request(`${base}/verify/84532/${address}`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})
    record.contracts[name]={address,identifier,...job};save()
    console.log(`${name}: verification submitted`)
  } catch(error) {record.contracts[name]={address,identifier,error:String(error)};save();console.log(`${name}: submission needs attention`)}
}
for(let pass=0;pass<30;pass++){
  let pending=false
  for(const [name,item] of Object.entries(record.contracts)){
    if(item.runtimeMatch==='exact_match'||item.error)continue
    try {
      const status=await request(`${base}/verify/${item.verificationId}`)
      if(!status.isJobCompleted){pending=true;continue}
      const verified=await request(`${base}/contract/84532/${item.address}`)
      record.contracts[name]={...item,...verified,job:status};save()
      console.log(`${name}: ${verified.runtimeMatch??'no runtime match'}`)
    }catch(error){record.contracts[name].error=String(error);save();console.log(`${name}: verification needs attention`)}
  }
  if(!pending)break
  await new Promise(resolve=>setTimeout(resolve,10_000))
}
const incomplete=Object.entries(record.contracts).filter(([,v])=>v.runtimeMatch!=='exact_match')
console.log(`Exact runtime matches: ${Object.keys(record.contracts).length-incomplete.length}/${Object.keys(record.contracts).length}`)
if(incomplete.length)process.exitCode=1
