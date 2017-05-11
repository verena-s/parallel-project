//standard includes
#include <iostream>
#include <vector>
#include <fstream>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <omp.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include <curand.h>
#include <curand_kernel.h>
#include <cublas_v2.h>

#include "CycleTimer.h"

#define BLOCKSIZE  1024
#define SCAN_BLOCK_DIM  BLOCKSIZE
#include "exclusiveScan.cu_inl"

//include definition file
#include "neuralNetwork.h"

//#include "/afs/cs/academic/class/15418-s17/public/sw/OpenBLAS/cblas.h"
//#include <openblas/cblas.h>
using namespace std;

void gpu_blas_mmul(cublasHandle_t &handle, const float *A, const float *B, float *C, const int m, const int k, const int n) {
	int lda=m, ldb=k, ldc=m;
	const float alf =1;
	const float bet =0;
	const float *alpha = &alf; 
	const float *beta =&bet;


	cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc);
}

__global__ void
forward_prop_kernel(float *device_output, float *input, float *weights, int num_first, int num_second) {
	int linearThreadIndex = threadIdx.x;
	int unit = blockIdx.x;

    __shared__ float prefixSumInput[BLOCKSIZE];
    __shared__ float prefixSumOutput[BLOCKSIZE];
    __shared__ float prefixSumScratch[2 * BLOCKSIZE];

    if (linearThreadIndex < num_first) {
    	prefixSumInput[linearThreadIndex] = input[linearThreadIndex] * weights[linearThreadIndex*num_second + unit];
    }

    __syncthreads();

    sharedMemExclusiveScan(linearThreadIndex, prefixSumInput, prefixSumOutput, 
                            prefixSumScratch, BLOCKSIZE);

    __syncthreads();

    if (linearThreadIndex == 0 && unit < num_second) {
    	// device_output[unit] = 1/(1+exp(-1*prefixSumOutput[num_first]));
    	device_output[unit] = prefixSumOutput[num_first];
    }
}


// first, second -> input=input+1, nhidden
// first, second -> hidden=hidden+1, noutput
__global__ void
forward_prop_kernel_batch(float *device_output, float *input, float *weights, int num_first, int num_second, int batchSize) {
	int linearThreadIndex = threadIdx.x;
	// PRINT LINEAR THREAD INDEX TO DEBUG 
	int unit = blockIdx.x%num_second;
	int batch = blockIdx.x/num_second;

    __shared__ float prefixSumInput[BLOCKSIZE];
    __shared__ float prefixSumOutput[BLOCKSIZE];
    __shared__ float prefixSumScratch[2 * BLOCKSIZE];

    if (linearThreadIndex < num_first) {
    	prefixSumInput[linearThreadIndex] = input[batch*linearThreadIndex] * weights[linearThreadIndex*num_second + unit];
    }

    __syncthreads();

    sharedMemExclusiveScan(linearThreadIndex, prefixSumInput, prefixSumOutput, 
                            prefixSumScratch, BLOCKSIZE);

    __syncthreads();

    if (linearThreadIndex == 0 && unit < num_second) {
    	device_output[batch*unit] = 1/(1+exp(-1*prefixSumOutput[num_first]));
    }
}


/*******************************************************************
* Constructor
********************************************************************/
neuralNetwork::neuralNetwork(int nI, int nH, int nO, int bS) : nInput(nI), nHidden(nH), nOutput(nO), batchSize(bS)
{				
	//create neuron lists
	//--------------------------------------------------------------------------------------------------------
	inputNeurons = new( float[batchSize*(nInput + 1)] );
        for (int b= 0; b<batchSize; b++) {
            for (int i=0; i<nInput+1; i++) {
                if (i==nInput) {
                    inputNeurons[(b+1)*(nInput)] = -1;
                }
                else {
                    inputNeurons[b*(nInput+1) + i] = 0;
                } 
            }
        }

	//create input bias neuron
	// inputNeurons[nInput] = -1;

	hiddenNeurons = new( float[batchSize*(nHidden + 1)] );
        for (int b=0; b<batchSize; b++) {
            for (int i=0; i<nHidden+1; i++) {
                if (i==nHidden) {
                    hiddenNeurons[(b+1)*(nHidden)] = -1;
                }
                else {
                    hiddenNeurons[b*(nHidden+1) + i] = 0; 
                }
            }
        }
	// for ( int i=0; i < nHidden; i++ ) hiddenNeurons[i] = 0;

	//create hidden bias neuron
	// hiddenNeurons[nHidden] = -1;

	// outputNeurons = new( float[nOutput] );
	outputNeurons = new( float[batchSize*(nOutput + 1)] );
	for ( int i=0; i < batchSize*(nOutput+1); i++ ) {
		outputNeurons[i] = 0;
	}

	// for ( int i=0; i < nOutput; i++ ) outputNeurons[i] = 0;

	//create weight lists (include bias neuron weights)
	//--------------------------------------------------------------------------------------------------------
	wInputHidden = new( float*[nInput + 1] );
	wInputHidden[0] = new (float[(nInput + 1)*nHidden]);
	for ( int i=1; i <= nInput; i++ ) {
		wInputHidden[i] = wInputHidden[i-1] + nHidden;
	}
	for ( int i=0; i <= nInput; i++ ) 
	{
		for ( int j=0; j < nHidden; j++ ) wInputHidden[i][j] = 0;		
	}

	wHiddenOutput = new( float*[nHidden + 1] );
	wHiddenOutput[0] = new (float[(nHidden + 1)*nOutput]);
	for ( int i=1; i <= nHidden; i++ ) {
		wHiddenOutput[i] = wHiddenOutput[i-1] + nOutput;
	}
	for ( int i=0; i <= nHidden; i++ ) 
	{
		for ( int j=0; j < nOutput; j++ ) wHiddenOutput[i][j] = 0;		
	}
	
	//initialize weights
	//--------------------------------------------------------------------------------------------------------
	initializeWeights();		
}

/*******************************************************************
* Destructor
********************************************************************/
neuralNetwork::~neuralNetwork()
{
	//delete neurons
	delete[] inputNeurons;
	delete[] hiddenNeurons;
	delete[] outputNeurons;

	//delete weight storage
	for (int i=0; i <= nInput; i++) delete[] wInputHidden[i];
	delete[] wInputHidden;

	for (int j=0; j <= nHidden; j++) delete[] wHiddenOutput[j];
	delete[] wHiddenOutput;

	
	cudaFree(device_output1);
	cudaFree(input);
	cudaFree(w1);

	cudaFree(device_output2);
	cudaFree(hidden);
	cudaFree(w2);
	
}

/*******************************************************************
* Save Neuron Weights
*******************************************************************/
bool neuralNetwork::saveWeights(char* filename)
{
	//open file for reading
	fstream outputFile;
	outputFile.open(filename, ios::out);

	if ( outputFile.is_open() )
	{
		outputFile.precision(50);		

		//output weights
		for ( int i=0; i <= nInput; i++ ) 
		{
			for ( int j=0; j < nHidden; j++ ) 
			{
				outputFile << wInputHidden[i][j] << ",";				
			}
		}
		
		for ( int i=0; i <= nHidden; i++ ) 
		{		
			for ( int j=0; j < nOutput; j++ ) 
			{
				outputFile << wHiddenOutput[i][j];					
				if ( i * nOutput + j + 1 != (nHidden + 1) * nOutput ) outputFile << ",";
			}
		}

		//print success
		cout << endl << "Neuron weights saved to '" << filename << "'" << endl;

		//close file
		outputFile.close();
		
		return true;
	}
	else 
	{
		cout << endl << "Error - Weight output file '" << filename << "' could not be created: " << endl;
		return false;
	}
}

/*******************************************************************
* Return the NN accuracy on the set
********************************************************************/
double neuralNetwork::getSetAccuracy( std::vector<dataEntry*>& set )
{
	double incorrectResults = 0;
		
	//for every training input array
	for ( int tp = 0; tp < (int) set.size(); tp++)
	{						
		//feed inputs through network and backpropagate errors
		feedForward( set[tp]->pattern );

		int predicted = distance(outputNeurons, max_element(outputNeurons, outputNeurons + nOutput));
		int expected = distance(set[tp]->target, max_element(set[tp]->target, set[tp]->target + nOutput));
		
		if (predicted != expected) incorrectResults++;	
		
	}//end for
	
	//calculate error and return as percentage
	return 100 - (incorrectResults/set.size() * 100);
}

/*******************************************************************
* Initialize Neuron Weights
********************************************************************/
void neuralNetwork::initializeWeights()
{
	double startTime = CycleTimer::currentSeconds();

	
	cudaMalloc(&device_output1, sizeof(float) * batchSize*nHidden);
    cudaMalloc(&input, sizeof(float) * batchSize*(nInput+1));
    cudaMalloc(&w1, sizeof(float) * (nInput+1)*nHidden);

    cudaMalloc(&device_output2, sizeof(float) * batchSize*nOutput);
    cudaMalloc(&hidden, sizeof(float) * batchSize*(nHidden+1));
    cudaMalloc(&w2, sizeof(float) * (nHidden+1)*nOutput);
    

	//set weights between input and hidden 		
	//--------------------------------------------------------------------------------------------------------
	for(int i = 0; i <= nInput; i++)
	{		
		for(int j = 0; j < nHidden; j++) 
		{
			//set weights to random values
			wInputHidden[i][j] = ( (( (float)(rand()%1000)+1)/1000)/10 - 0.05);
		}
	}
	
	//set weights between input and hidden
	//--------------------------------------------------------------------------------------------------------
	for(int i = 0; i <= nHidden; i++)
	{		
		for(int j = 0; j < nOutput; j++) 
		{
			//set weights to random values
			wHiddenOutput[i][j] = ( (( (float)(rand()%1000)+1)/1000)/10 - 0.05);
		}
	}
	double endTime = CycleTimer::currentSeconds();
    double overallDuration = endTime - startTime;

    printf("Time Taken Seq:%f\n", overallDuration);
}
/*******************************************************************
* Activation Function
********************************************************************/
inline float neuralNetwork::activationFunction( float x )
{
	//sigmoid function
	return 1/(1+exp(-x));
}	

void neuralNetwork::feedForwardBatch(vector<float*> patternVector) {
	double startTime = CycleTimer::currentSeconds();

	for (int b = 0; b<batchSize; b++) {
	    for(int i = 0; i < nInput+1; i++) { 
                if (i!=nInput) {
                    inputNeurons[b*(nInput+1) + i] = patternVector[b][i];
                }
            }
	}

	dim3 blockDim(1024, 1);
    dim3 gridDim(1024);//((1024*1024) + blockDim.x - 1) / blockDim.x);
    cudaMemcpy(input, inputNeurons, sizeof(float) * batchSize*(nInput+1), cudaMemcpyHostToDevice);
    cudaMemcpy(w1, wInputHidden[0], (nInput+1)*nHidden*sizeof(float), cudaMemcpyHostToDevice);
    forward_prop_kernel_batch<<<gridDim, blockDim>>>(device_output1, input, w1, nInput+1, nHidden, batchSize);
    cudaThreadSynchronize();
    cudaMemcpy(hiddenNeurons, device_output1, batchSize*nHidden*sizeof(float), cudaMemcpyDeviceToHost);

    //w2 part
    dim3 gridDim2(nOutput*batchSize);//((1024*1024) + blockDim.x - 1) / blockDim.x);
	cudaMemcpy(hidden, hiddenNeurons, sizeof(float) * batchSize*(nHidden+1), cudaMemcpyHostToDevice);
	cudaMemcpy(w2, wHiddenOutput[0], (nHidden+1)*nOutput*sizeof(float), cudaMemcpyHostToDevice);
	forward_prop_kernel_batch<<<gridDim2, blockDim>>>(device_output2, hidden, w2, nHidden+1, nOutput,batchSize);
	cudaThreadSynchronize();
	cudaMemcpy(outputNeurons, device_output2, batchSize*nOutput*sizeof(float), cudaMemcpyDeviceToHost);

    //    dim3 gridDim2(nOutput);//((1024*1024) + blockDim.x - 1) / blockDim.x);
	
 //    cudaMemcpy(hidden, hiddenNeurons, sizeof(float) * (nHidden+1), cudaMemcpyHostToDevice);
 //    // float endTime1 = CycleTimer::currentSeconds();
    
 //    cudaMemcpy(w2, wHiddenOutput[0], (nHidden+1)*nOutput*sizeof(float), cudaMemcpyHostToDevice);
 //    // double endTime2 = CycleTimer::currentSeconds();

	// forward_prop_kernel<<<gridDim2, blockDim>>>(device_output2, hidden, w2, nHidden+1, nOutput);

	// cudaThreadSynchronize();
	// // double endTime3 = CycleTimer::currentSeconds();

	// cudaMemcpy(outputNeurons, device_output2, nOutput*sizeof(float), cudaMemcpyDeviceToHost);

	double endTime = CycleTimer::currentSeconds();
	double time = endTime - startTime;

	cout << "Forward = " << time << endl;

}

/*******************************************************************
* Feed Forward Operation
********************************************************************/
void neuralNetwork::feedForward(float* pattern)
{
	//set input neurons to input values
	for(int i = 0; i < nInput; i++) {
		inputNeurons[i] = pattern[i];
	}


	double startTime = CycleTimer::currentSeconds();
	// double startTime = CycleTimer::currentSeconds();
	
	
	dim3 blockDim(1024, 1);
        dim3 gridDim(nHidden);//((1024*1024) + blockDim.x - 1) / blockDim.x);
	
    cudaMemcpy(input, inputNeurons, sizeof(float) * (nInput+1), cudaMemcpyHostToDevice);
    //double endTime1 = CycleTimer::currentSeconds();
    
    cudaMemcpy(w1, wInputHidden[0], (nInput+1)*nHidden*sizeof(float), cudaMemcpyHostToDevice);
    // double endTime2 = CycleTimer::currentSeconds();

	forward_prop_kernel<<<gridDim, blockDim>>>(device_output1, input, w1, nInput+1, nHidden);

	cudaThreadSynchronize();
	// // double endTime3 = CycleTimer::currentSeconds();

        cudaMemcpy(hiddenNeurons, device_output1, nHidden*sizeof(float), cudaMemcpyDeviceToHost);
	// // double endTime4 = CycleTimer::currentSeconds();


	/*cublasHandle_t handle;
	cublasCreate(&handle);

	gpu_blas_mmul(handle, input, w1, device_output1, 1, nInput+1, nHidden);

	cudaMemcpy(hiddenNeurons, device_output1, nHidden*sizeof(float), cudaMemcpyDeviceToHost);


	cublasDestroy(handle);*/
	
        /*float alpha = 1.0;
        float beta = 0.0;
        float* tempWeights = new float[(nInput+1)*nHidden];
        for (int i=0; i<nInput +1; i++) {
            for (int j=0; j<nHidden; j++) {
                tempWeights[i*nHidden + j] = wInputHidden[i][j];
            }
        }
        
	cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 1, nHidden, nInput+1, alpha, inputNeurons, nInput+1, tempWeights, nHidden, beta, hiddenNeurons, nHidden);*/
	
	// double time1 = endTime1 - startTime;
	// double time2 = endTime2 - endTime1;
	// double time3 = endTime3 - endTime2;
	// double time4 = endTime4 - endTime3;

 //    printf("Time 1:%f\n", time1);
 //    printf("Time 2:%f\n", time2);
 //    printf("Time 3:%f\n", time3);
 //    printf("Time 4:%f\n", time4);


    //Calculate Hidden Layer values - include bias neuron
	//--------------------------------------------------------------------------------------------------------
	
	#pragma omp parallel 
	{
		#pragma omp for
		for (int j = 0; j<nHidden; j++) {
			hiddenNeurons[j] = activationFunction( hiddenNeurons[j] );
		}
		// float temp = 0.0;
		/*
		// #pragma omp for //schedule(static, 16)
		for(int j=0; j < nHidden; j++)
		{
			temp = 0.0;
			//clear value
			hiddenNeurons[j] = 0;	
			//get weighted sum of pattern and bias neuron
		 	// #pragma omp parallel for reduction(+ : temp)
			for( int i=0; i <= nInput; i++ ) {
				temp += inputNeurons[i] * wInputHidden[i][j];
			}
			// cout << "temp: " << hiddenNeurons[j] << endl;
			//set to result of sigmoid
			hiddenNeurons[j] = activationFunction( temp );			
			// cout << "output: " << hiddenNeurons[j] << endl;
		}
		*/
	
		// double endTime1 = CycleTimer::currentSeconds();
		// printf("Time:%f\n", endTime1 - startTime);
		//Calculating Output Layer values - include bias neuron
		//--------------------------------------------------------------------------------------------------------
		#pragma omp for //schedule(static, 16)//reduction(+ : temp)
		for(int k=0; k < nOutput; k++)
		{
			float temp = 0.0;
			//clear value
			outputNeurons[k] = 0;			
					
			//get weighted sum of pattern and bias neuron
			// #pragma omp for //reduction(+ : temp)
			for( int j=0; j <= nHidden; j++ ) {
				temp += hiddenNeurons[j] * wHiddenOutput[j][k];
			}
			//set to result of sigmoid
			outputNeurons[k] = activationFunction( temp );
		}
	}
	
	
	
/*
    dim3 gridDim2(nOutput);//((1024*1024) + blockDim.x - 1) / blockDim.x);
	
    cudaMemcpy(hidden, hiddenNeurons, sizeof(float) * (nHidden+1), cudaMemcpyHostToDevice);
    // double endTime1 = CycleTimer::currentSeconds();
    
    cudaMemcpy(w2, wHiddenOutput[0], (nHidden+1)*nOutput*sizeof(float), cudaMemcpyHostToDevice);
    // double endTime2 = CycleTimer::currentSeconds();

	forward_prop_kernel<<<gridDim2, blockDim>>>(device_output2, hidden, w2, nHidden+1, nOutput);

	cudaThreadSynchronize();
	// double endTime3 = CycleTimer::currentSeconds();

	cudaMemcpy(outputNeurons, device_output2, nOutput*sizeof(float), cudaMemcpyDeviceToHost);
	// double endTime4 = CycleTimer::currentSeconds();
*/

	double endTime3 = CycleTimer::currentSeconds();

	double time = endTime3 - startTime;

	// cout << "Forward = " << time << endl;
	
}

void neuralNetwork::printCudaInfo()
{
    // for fun, just print out some stats on the machine

    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++)
    {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n",
               static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n"); 
}

