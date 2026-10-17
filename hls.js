const { spawn } = require('child_process');
const fs = require('fs/promises');
const path = require('path');

/** Create 360p, 540p and 720p HLS renditions. Run only in a worker with FFmpeg installed. */
async function transcodeVideoToAdaptiveHLS(inputPath, outputDir) {
  await fs.mkdir(path.join(outputDir, 'v0'), { recursive: true });
  await fs.mkdir(path.join(outputDir, 'v1'), { recursive: true });
  await fs.mkdir(path.join(outputDir, 'v2'), { recursive: true });
  const ffmpeg = process.env.FFMPEG_PATH || 'ffmpeg';
  const master = path.join(outputDir, 'master.m3u8');
  const segmentPattern = path.join(outputDir, 'v%v', 'segment_%03d.ts');
  const filters = '[0:v]split=3[v0][v1][v2];' +
    '[v0]scale=360:640:force_original_aspect_ratio=decrease,pad=360:640:(ow-iw)/2:(oh-ih)/2[v0out];' +
    '[v1]scale=540:960:force_original_aspect_ratio=decrease,pad=540:960:(ow-iw)/2:(oh-ih)/2[v1out];' +
    '[v2]scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2[v2out]';
  const args = [
    '-y', '-i', inputPath, '-filter_complex', filters,
    '-map', '[v0out]', '-map', '0:a:0?', '-c:v:0', 'libx264', '-preset', 'veryfast', '-b:v:0', '650k', '-maxrate:v:0', '715k', '-bufsize:v:0', '1300k', '-c:a:0', 'aac', '-b:a:0', '64k',
    '-map', '[v1out]', '-map', '0:a:0?', '-c:v:1', 'libx264', '-preset', 'veryfast', '-b:v:1', '1300k', '-maxrate:v:1', '1430k', '-bufsize:v:1', '2600k', '-c:a:1', 'aac', '-b:a:1', '96k',
    '-map', '[v2out]', '-map', '0:a:0?', '-c:v:2', 'libx264', '-preset', 'veryfast', '-b:v:2', '2500k', '-maxrate:v:2', '2750k', '-bufsize:v:2', '5000k', '-c:a:2', 'aac', '-b:a:2', '128k',
    '-f', 'hls', '-hls_time', '4', '-hls_playlist_type', 'vod', '-hls_flags', 'independent_segments',
    '-hls_segment_filename', segmentPattern, '-var_stream_map', 'v:0,a:0 v:1,a:1 v:2,a:2', '-master_pl_name', 'master.m3u8',
    path.join(outputDir, 'v%v.m3u8')
  ];
  await new Promise((resolve, reject) => {
    const proc = spawn(ffmpeg, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    proc.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-12000); });
    proc.on('error', reject);
    proc.on('close', code => code === 0 ? resolve() : reject(new Error(`FFmpeg exited ${code}: ${stderr}`)));
  });
  await fs.access(master);
  return master;
}
module.exports = { transcodeVideoToAdaptiveHLS };
