import { spawn } from 'child_process';
import pidusage from 'pidusage';
import autocannon from 'autocannon';

const startBackend = () => {
    return new Promise((resolve, reject) => {
        console.log('Starting backend server...');
        const backend = spawn('node', ['src/index.js'], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
        
        backend.stdout.on('data', (data) => {
            const output = data.toString();
            // Wait for the server to be ready
            if (output.includes('Server running on')) {
                resolve(backend);
            }
        });

        backend.stderr.on('data', (data) => {
            const output = data.toString();
            // Only reject if it hasn't started yet
            if (output.includes('Error:')) {
                console.error(output);
            }
        });

        backend.on('error', (err) => {
            reject(err);
        });
    });
};

const runStressTest = (backendPid) => {
    return new Promise((resolve, reject) => {
        console.log('Starting autocannon load test...');
        
        let maxMemory = 0;
        let maxCpu = 0;

        // Poll resource usage every 100ms
        const interval = setInterval(async () => {
            try {
                const stats = await pidusage(backendPid);
                if (stats.memory > maxMemory) maxMemory = stats.memory;
                if (stats.cpu > maxCpu) maxCpu = stats.cpu;
            } catch (err) {
                // Process might be dead
            }
        }, 100);

        const instance = autocannon({
            url: 'http://localhost:3002/health',
            connections: 100,
            duration: 10,
            pipelining: 1
        }, (err, result) => {
            clearInterval(interval);
            if (err) return reject(err);
            resolve({ result, maxMemory, maxCpu });
        });
        
        autocannon.track(instance, {renderProgressBar: false});
    });
};

const main = async () => {
    let backend;
    try {
        backend = await startBackend();
        console.log(`Backend started with PID: ${backend.pid}`);
        
        const { result, maxMemory, maxCpu } = await runStressTest(backend.pid);
        
        console.log('\n--- Load Test Results ---');
        console.log(`Max CPU: ${maxCpu.toFixed(2)}%`);
        console.log(`Max Memory: ${(maxMemory / 1024 / 1024).toFixed(2)} MB`);
        console.log(`Total Requests: ${result.requests.total}`);
        console.log(`Errors: ${result.errors}`);
        console.log(`Timeouts: ${result.timeouts}`);
        console.log(`Average Latency: ${result.latency.average} ms`);
        
    } catch (err) {
        console.error('Stress test failed:', err);
    } finally {
        if (backend) {
            console.log('Killing backend server...');
            backend.kill();
        }
        process.exit(0);
    }
};

main();
