#include "layer.h"
#include <cstdio>
// Constructor
Layer::Layer(int M, int N, int O)
{
	this->M = M;
	this->N = N;
	this->O = O;

	float h_bias[N];
	float h_weight[N][M];
	cudaEvent_t start, stop;
  	cudaEventCreate(&start);
  	cudaEventCreate(&stop);
	output = NULL;
	preact = NULL;
	bias   = NULL;
	weight = NULL;

	for (int i = 0; i < N; ++i) {
		h_bias[i] = 0.5f - float(rand()) / float(RAND_MAX);
		/*h_bias[i] = 0.0f;*/

		for (int j = 0; j < M; ++j) {
			h_weight[i][j] = 0.5f - float(rand()) / float(RAND_MAX);
			/*h_weight[i][j] = 0.05f;*/
		}
	}

	cudaMalloc(&output, sizeof(float) * O);
	cudaMalloc(&preact, sizeof(float) * O);

	cudaMalloc(&bias, sizeof(float) * N);

	cudaMalloc(&weight, sizeof(float) * M * N);

	cudaMalloc(&d_output, sizeof(float) * O);
	cudaMalloc(&d_preact, sizeof(float) * O);
	cudaMalloc(&d_weight, sizeof(float) * M * N);
	cudaEventRecord(start,0);
	cudaMemcpy(bias, h_bias, sizeof(float) * N, cudaMemcpyHostToDevice);

	cudaMemcpy(weight, h_weight, sizeof(float) * M * N, cudaMemcpyHostToDevice);
	cudaEventRecord(stop,0);
	cudaEventSynchronize(stop);
  	float milliseconds;
  	cudaEventElapsedTime(&milliseconds, start, stop);
	fprintf(stdout ,"millisecond : %f\n", milliseconds);
	cudaEventDestroy(start);
  	cudaEventDestroy(stop);
	
}

// Destructor
Layer::~Layer()
{
	cudaFree(output);
	cudaFree(preact);

	cudaFree(bias);

	cudaFree(weight);

	cudaFree(d_output);
	cudaFree(d_preact);
	cudaFree(d_weight);
}

// Send data one row from dataset to the GPU
void Layer::setOutput(float *data)
{
	cudaMemcpy(output, data, sizeof(float) * O, cudaMemcpyHostToDevice);
}

// Reset GPU memory between iterations
void Layer::clear()
{
	cudaMemset(output, 0x00, sizeof(float) * O);
	cudaMemset(preact, 0x00, sizeof(float) * O);
}

void Layer::bp_clear()
{
	cudaMemset(d_output, 0x00, sizeof(float) * O);
	cudaMemset(d_preact, 0x00, sizeof(float) * O);
	cudaMemset(d_weight, 0x00, sizeof(float) * M * N);
}


__device__ float step_function(float v) //Sigmoid function::Activation Function
{
	return 1 / (1 + exp(-v));
}

__global__ void apply_step_function(float *input, float *output, const int N)
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		output[idx] = step_function(input[idx]);
	}
}

__global__ void makeError(float *err, float *output, unsigned int Y, const int N)
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;// find specific index/thread in GPU
	const int size = blockDim.x * gridDim.x; // the size of all index/thread in GPU

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		err[idx] = ((Y == idx ? 1.0f : 0.0f) - output[idx]);
	}
}

__global__ void apply_grad(float *output, float *grad, const int N)
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		output[idx] += dt * grad[idx];
	}
}

//conv1 28*28 to 24*24*6
__global__ void fp_preact_c1(float input[28][28], float preact[6][24][24], float weight[6][5][5])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 5*5*6*24*24;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 5);
		const int i2 = ((idx /= 5	) % 5);
		const int i3 = ((idx /= 5	) % 6);
		const int i4 = ((idx /= 6	) % 24);
		const int i5 = ((idx /= 24	) % 24);

		atomicAdd(&preact[i3][i4][i5], weight[i3][i1][i2] * input[i4 + i1][i5 + i2]);
	}
}

__global__ void fp_bias_c1(float preact[6][24][24], float bias[6])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*24*24;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 24);
		const int i3 = ((idx /= 24	) % 24);

		preact[i1][i2][i3] += bias[i1];
	}
}

//pooling 1 24*24*6 to 12*12*6
__global__ void fp_preact_s1(float input[6][24][24], float preact[6][12][12], float weight[1][2][2])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 2*2*6*12*12;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 2);
		const int i2 = ((idx /= 2	) % 2);
		const int i3 = ((idx /= 2	) % 6);
		const int i4 = ((idx /= 6	) % 12);
		const int i5 = ((idx /= 12	) % 12);

		atomicAdd(&preact[i3][i4][i5], (input[i3][i4*2+i1][i5*2+i2] > preact[i3][i4][i5]) * (input[i3][i4 * 2 + i1][i5 * 2 + i2] - preact[i3][i4][i5]));
	}
}

__global__ void fp_bias_s1(float preact[6][12][12], float bias[1])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*12*12;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 12);
		const int i3 = ((idx /= 12	) % 12);

		preact[i1][i2][i3] += bias[0];
	}
}

//conv2 12*12*6 to 8*8*16
__global__ void fp_preact_c2(float input[6][12][12], float preact[16][8][8], float weight[16][6][5][5])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 5*5*6*16*8*8;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 5);
		const int i2 = ((idx /= 5	) % 5);				
		const int i3 = ((idx /= 5	) % 6);
		const int i6 = ((idx /= 6	) % 16);
		const int i4 = ((idx /= 16	) % 8);
		const int i5 = ((idx /= 8	) % 8);

		atomicAdd(&preact[i6][i4][i5], weight[i6][i3][i1][i2] * input[i3][i4 + i1][i5 + i2]);
	}
}

__global__ void fp_bias_c2(float preact[16][8][8], float bias[16])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*8*8;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 8);
		const int i3 = ((idx /= 8	) % 8);

		preact[i1][i2][i3] += bias[i1];
	}
}

//pooling 2 8*8*16 to 4*4*16
__global__ void fp_preact_s2(float input[16][8][8], float preact[16][4][4], float weight[1][2][2])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 2*2*16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 2);
		const int i2 = ((idx /= 2	) % 2);
		const int i3 = ((idx /= 2	) % 16);
		const int i4 = ((idx /= 16	) % 4);
		const int i5 = ((idx /= 4	) % 4);

		atomicAdd(&preact[i3][i4][i5], (input[i3][i4*2+i1][i5*2+i2] > preact[i3][i4][i5]) * (input[i3][i4 * 2 + i1][i5 * 2 + i2] - preact[i3][i4][i5]));
		//atomicAdd(&preact[i3][i4][i5], weight[0][i1][i2] * input[i3][i4 * 2 + i1][i5 * 2 + i2]);
	}
}

__global__ void fp_bias_s2(float preact[16][4][4], float bias[1])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 4);
		const int i3 = ((idx /= 4	) % 4);

		preact[i1][i2][i3] += bias[0];
	}
}

//conv3 4*4*16 to 1*1*120
__global__ void fp_preact_c3(float input[16][4][4], float preact[120], float weight[120][16][4][4])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 4*4*16*120*1*1;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 4);
		const int i2 = ((idx /= 4	) % 4);				
		const int i3 = ((idx /= 4	) % 16);
		const int i6 = ((idx /= 16	) % 120);
		atomicAdd(&preact[i6], weight[i6][i3][i1][i2] * input[i3][i1][i2]);
	}
}

__global__ void fp_bias_c3(float preact[120], float bias[120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 120*1*1;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 120);

		preact[i1] += bias[i1];
	}
}



//full connect 1 120 to 84
__global__ void fp_preact_f1(float input[120], float preact[84], float weight[84][120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84*120*1*1;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 84);
		const int i2 = ((idx /= 10	) % 120);

		atomicAdd(&preact[i1], weight[i1][i2] * input[i2]);
	}
}

__global__ void fp_bias_f1(float preact[84], float bias[84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		preact[idx] += bias[idx];
	}
}

//full connect 2 84 to 10
__global__ void fp_preact_f2(float input[84], float preact[10], float weight[10][84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 10*84*1*1;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 10);
		const int i2 = ((idx /= 10	) % 84);

		atomicAdd(&preact[i1], weight[i1][i2] * input[i2]);
	}
}

__global__ void fp_bias_f2(float preact[10], float bias[10])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 10;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		preact[idx] += bias[idx];
	}
}


//back prop start
// output to f2
__global__ void bp_weight_f2(float d_weight[10][84], float d_preact[10], float p_output[84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 10*84;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 10);
		const int i2 = ((idx /= 10	) % 84);

		d_weight[i1][i2] = d_preact[i1] * p_output[i2];
	}
}

__global__ void bp_bias_f2(float bias[10], float d_preact[10])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 10;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		bias[idx] += dt * d_preact[idx];
	}
}

// output to f1
__global__ void bp_output_f1(float d_output[84], float n_weight[10][84], float nd_preact[10])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 10*84;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 10);
		const int i2 = ((idx /= 10	) % 84);

		atomicAdd(&d_output[i2], n_weight[i1][i2] * nd_preact[i1]);
	}
}

__global__ void bp_preact_f1(float d_preact[84], float d_output[84], float preact[84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 84);

		const float o = step_function(preact[i1]);

		d_preact[i1] = d_output[i1] * o * (1 - o);
	}
}



__global__ void bp_weight_f1(float d_weight[84][120], float d_preact[84], float p_output[120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84*120;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 84);
		const int i2 = ((idx /= 84	) % 120);

		d_weight[i1][i2] = d_preact[i1] * p_output[i2];
	}
}

__global__ void bp_bias_f1(float bias[84], float d_preact[84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84;

	for (int idx = N * pos / size; idx < N * (pos+1) / size; ++idx) {
		bias[idx] += dt * d_preact[idx];
	}
}

// output to c3
__global__ void bp_output_c3(float d_output[120], float n_weight[84][120], float nd_preact[84])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 84*120;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 84);
		const int i2 = ((idx /= 84	) % 120);

		atomicAdd(&d_output[i2], n_weight[i1][i2] * nd_preact[i1]);
	}
}

__global__ void bp_preact_c3(float d_preact[120], float d_output[120], float preact[120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 120;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 120);

		const float o = step_function(preact[i1]);

		d_preact[i1] = d_output[i1] * o * (1 - o);
	}
}

__global__ void bp_weight_c3(float d_weight[120][16][4][4], float d_preact[120], float p_output[16][4][4])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 120*16*4*4;
	const float d = 16.0f*4.0f*4.0f;
	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 120);
		const int i2 = ((idx /= 120	) % 16);
		const int i3 = ((idx /= 16	) % 4);
		const int i4 = ((idx /= 4	) % 4);

		atomicAdd(&d_weight[i1][i2][i3][i4], d_preact[i1] * p_output[i2][i3][i4]/d);
	}
}

__global__ void bp_bias_c3(float bias[120], float d_preact[120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 120;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 120);
		atomicAdd(&bias[i1], dt * d_preact[i1]);
	}
}

// output to s2
__global__ void bp_output_s2(float d_output[16][4][4], float n_weight[120][16][4][4], float nd_preact[120])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 4*4*16*120;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 4);
		const int i2 = ((idx /= 4	) % 4);
		const int i3 = ((idx /= 4	) % 16);
		const int i4 = ((idx /= 16	) % 120);
		atomicAdd(&d_output[i3][i1][i2], n_weight[i4][i3][i1][i2] * nd_preact[i4]);
	}
}

__global__ void bp_preact_s2(float d_preact[16][4][4], float d_output[16][4][4], float preact[16][4][4])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 4);
		const int i3 = ((idx /= 4	) % 4);

		const float o = step_function(preact[i1][i2][i3]);

		d_preact[i1][i2][i3] = d_output[i1][i2][i3] * o * (1 - o);
	}
}

__global__ void bp_weight_s2(float d_weight[1][2][2], float d_preact[16][4][4], float p_output[16][8][8])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 1*2*2*16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 1);
		const int i2 = ((idx /= 1	) % 2);
		const int i3 = ((idx /= 2	) % 2);
		const int i4 = ((idx /= 2	) % 16);
		const int i5 = ((idx /= 16	) % 4);
		const int i6 = ((idx /= 4	) % 4);

		atomicAdd(&d_weight[i1][i2][i3], d_preact[i4][i5][i6] * p_output[i4][i5 * 2 + i2][i6 * 2 + i3]);
	}
}

__global__ void bp_bias_s2(float bias[1], float d_preact[16][4][4])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 4);
		const int i3 = ((idx /= 4	) % 4);
		atomicAdd(&bias[0], dt * d_preact[i1][i2][i3]/N);
	}
}

// output to c2
__global__ void bp_output_c2(float d_output[16][8][8], float n_weight[16][8][8], float nd_preact[16][4][4], float d_preact[16][4][4])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 1*2*2*16*4*4;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 1);
		const int i2 = ((idx /= 1	) % 2);
		const int i3 = ((idx /= 2	) % 2);
		const int i4 = ((idx /= 2	) % 16);
		const int i5 = ((idx /= 16	) % 4);
		const int i6 = ((idx /= 4	) % 4);

		atomicAdd(&d_output[i4][i5 * 2 + i2][i6 * 2 + i3], (n_weight[i4][i5*2 + i2][i6*2 + i3] == d_preact[i4][i5][i6]) * nd_preact[i4][i5][i6]);
	}
}

__global__ void bp_preact_c2(float d_preact[16][8][8], float d_output[16][8][8], float preact[16][8][8])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16 * 8 * 8;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 8);
		const int i3 = ((idx /= 8	) % 8);

		//const float o = step_function(preact[i1][i2][i3]);

		d_preact[i1][i2][i3] = d_output[i1][i2][i3] * 1;
	}
}

__global__ void bp_weight_c2(float d_weight[16][6][5][5], float d_preact[16][8][8], float p_output[6][12][12])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*6*5*5*8*8;
	const float d = pow(8.0f, 2.0f);
	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 6);
		const int i3 = ((idx /= 6	) % 5);
		const int i4 = ((idx /= 5	) % 5);
		const int i5 = ((idx /= 5	) % 8);
		const int i6 = ((idx /= 8	) % 8);

		atomicAdd(&d_weight[i1][i2][i3][i4], d_preact[i1][i5][i6] * p_output[i2][i5+i3][i6+i4]/d);
	}
}

__global__ void bp_bias_c2(float bias[16], float d_preact[16][8][8])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*8*8;
	const float d = pow(8.0f, 2.0f);
	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1 ) % 16);
  		const int i2 = ((idx /= 16 ) % 8);
  		const int i3 = ((idx /= 8 ) % 8);

  		atomicAdd(&bias[i1], dt * d_preact[i1][i2][i3] / d);	
	}
}

//output s1
__global__ void bp_output_s1(float d_output[6][12][12], float n_weight[16][6][5][5], float nd_preact[16][8][8])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 16*6*5*5*8*8;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 16);
		const int i2 = ((idx /= 16	) % 6);
		const int i3 = ((idx /= 6	) % 5);
		const int i4 = ((idx /= 5	) % 5);
		const int i5 = ((idx /= 5	) % 8);
		const int i6 = ((idx /= 8	) % 8);

		atomicAdd(&d_output[i2][i3+i5][i4+i6], n_weight[i1][i2][i3][i4] * nd_preact[i1][i5][i6]);
	}
}

__global__ void bp_preact_s1(float d_preact[6][12][12], float d_output[6][12][12], float preact[6][12][12])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*12*12;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 12);
		const int i3 = ((idx /= 12	) % 12);

		const float o = step_function(preact[i1][i2][i3]);

		d_preact[i1][i2][i3] = d_output[i1][i2][i3] * o * (1 - o);
	}
}

__global__ void bp_weight_s1(float d_weight[1][2][2], float d_preact[6][12][12], float p_output[6][24][24])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 1*2*2*6*12*12;
	const float d = pow(6.0f, 3.0f);

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 1);
		const int i2 = ((idx /= 1	) % 2);
		const int i3 = ((idx /= 2	) % 2);
		const int i4 = ((idx /= 2	) % 6);
		const int i5 = ((idx /= 6	) % 12);
		const int i6 = ((idx /= 12	) % 12);

		atomicAdd(&d_weight[i1][i2][i3], d_preact[i4][i5][i6] * p_output[i4][i5 * 2 + i2][i6 * 2 + i3]);
	}
}

__global__ void bp_bias_s1(float bias[1], float d_preact[6][12][12])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*12*12;
	//const float d = pow(6.0f, 3.0f);

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 12);
		const int i3 = ((idx /= 12	) % 12);

		atomicAdd(&bias[0], dt * d_preact[i1][i2][i3] / N);
	}
}

//output c1
__global__ void bp_output_c1(float d_output[6][24][24], float n_weight[6][24][24], float nd_preact[6][12][12], float d_preact[6][12][12])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 1*2*2*6*12*12;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 1);
		const int i2 = ((idx /= 1	) % 2);
		const int i3 = ((idx /= 2	) % 2);
		const int i4 = ((idx /= 2	) % 6);
		const int i5 = ((idx /= 6	) % 12);
		const int i6 = ((idx /= 12	) % 12);

		atomicAdd(&d_output[i4][i5 * 2 + i2][i6 * 2 + i3], (n_weight[i4][i5*2 + i2][i6*2 + i3] == d_preact[i4][i5][i6]) * nd_preact[i4][i5][i6]);
		//atomicAdd(&d_output[i4][i5 * 2 + i2][i6 * 2 + i3], n_weight[i1][i2][i3] * nd_preact[i4][i5][i6]);
	}
}

__global__ void bp_preact_c1(float d_preact[6][24][24], float d_output[6][24][24], float preact[6][24][24])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*24*24;

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 24);
		const int i3 = ((idx /= 24	) % 24);

		const float o = step_function(preact[i1][i2][i3]);

		d_preact[i1][i2][i3] = d_output[i1][i2][i3] * o * (1 - o);
	}
}

__global__ void bp_weight_c1(float d_weight[6][5][5], float d_preact[6][24][24], float p_output[28][28])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*5*5*24*24;
	const float d = pow(24.0f, 2.0f);

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 5);
		const int i3 = ((idx /= 5	) % 5);
		const int i4 = ((idx /= 5	) % 24);
		const int i5 = ((idx /= 24	) % 24);

		atomicAdd(&d_weight[i1][i2][i3], d_preact[i1][i4][i5] * p_output[i4 + i2][i5 + i3] / d);
	}
}

__global__ void bp_bias_c1(float bias[6], float d_preact[6][24][24])
{
	const int pos = blockIdx.x * blockDim.x + threadIdx.x;
	const int size = blockDim.x * gridDim.x;

	const int N = 6*24*24;
	const float d = pow(24.0f, 2.0f);

	for (int n = N * pos / size; n < N * (pos+1) / size; ++n) {
		int idx = n;
		const int i1 = ((idx /= 1	) % 6);
		const int i2 = ((idx /= 6	) % 24);
		const int i3 = ((idx /= 24	) % 24);

		atomicAdd(&bias[i1], dt * d_preact[i1][i2][i3] / d);
	}
}
