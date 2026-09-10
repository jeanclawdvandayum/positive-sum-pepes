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
  descriptor:manifest.features?.PEPE_DNA_VERSION === '2' || manifest.artifacts?.descriptor?.contract === 'PepeExpandedDescriptor' ? 'src/PepeExpandedDescriptor.sol:PepeExpandedDescriptor' : 'src/PepeDescriptor.sol:PepeDescriptor', hookDeployer:'src/HookDeployer.sol:HookDeployer',
  controllerDeployer:'src/ControllerDeployer.sol:ControllerDeployer', stakerDeployer:'src/StakerDeployer.sol:StakerDeployer',
  tokenDeployer:'src/ControllerDeployer.sol:TokenDeployer',
  hookInitCode:'src/HookInitCode.sol:HookInitCode',
}
const builds = fs.readdirSync(buildDirectory).filter(f=>f.endsWith('.json')).map(f=>JSON.parse(fs.readFileSync(path.join(buildDirectory,f))))
const base = 'https://sourcify.dev/server/v2'
// This release uses bytecodeHash=none. Sourcify verifies executable code as
// "match"; "exact_match" additionally requires a matching source metadata hash.
const matched = item => ['match', 'exact_match'].includes(item?.runtimeMatch)
  && ['match', 'exact_match'].includes(item?.creationMatch)
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
  if(previous?.address?.toLowerCase()===address.toLowerCase() && matched(previous))continue
  try {
    const existing = await request(`${base}/contract/84532/${address}`).catch(() => null)
    if (matched(existing)) {
      record.contracts[name] = { address, identifier, ...existing }
      save(); console.log(`${name}: already verified`); continue
    }
    // Foundry build-info also contains CLI-only path/version fields, which
    // Sourcify correctly rejects as unsupported standard-JSON properties.
    const {language,sources,settings}=build.input
    const compilerVersion=JSON.parse(build.output.contracts[source][contract].metadata).compiler.version
    const body={stdJsonInput:{language,sources,settings},compilerVersion,contractIdentifier:identifier}
    const job=await request(`${base}/verify/84532/${address}`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})
    record.contracts[name]={address,identifier,...job};save()
    console.log(`${name}: verification submitted`)
  } catch(error) {record.contracts[name]={address,identifier,error:String(error)};save();console.log(`${name}: submission needs attention`)}
}
for(let pass=0;pass<30;pass++){
  let pending=false
  for(const [name,item] of Object.entries(record.contracts)){
    if(matched(item)||item.error)continue
    try {
      const status=await request(`${base}/verify/${item.verificationId}`)
      if(!status.isJobCompleted){pending=true;continue}
      if(status.error && status.error.customCode !== 'already_verified')throw Error(`${status.error.customCode}: ${status.error.message}`)
      const verified=await request(`${base}/contract/84532/${item.address}`)
      record.contracts[name]={...item,...verified,job:status};save()
      console.log(`${name}: ${verified.runtimeMatch??'no runtime match'}`)
    }catch(error){record.contracts[name].error=String(error);save();console.log(`${name}: verification needs attention`)}
  }
  if(!pending)break
  await new Promise(resolve=>setTimeout(resolve,10_000))
}
const incomplete=Object.entries(record.contracts).filter(([,v])=>!matched(v))
console.log(`Verified creation/runtime matches: ${Object.keys(record.contracts).length-incomplete.length}/${Object.keys(record.contracts).length}`)
if(incomplete.length)process.exitCode=1
