#include <iostream>
#include <fstream>
#include <R.h>

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

__global__ void Rkendall_gpu_atomic(const double* col1, const double* col2, const int n, const int m, unsigned long long* R){
  int row1 = blockIdx.y * blockDim.y + threadIdx.y;
  int row2 = blockIdx.x * blockDim.x + threadIdx.x;
  if (row1 < row2 && row2 < n){
    if ((col1[row1] - col1[row2]) * (col2[row1] - col2[row2]) < 0){
      atomicAdd(R, 1);
    }
  }
}

__global__ void Rkendall_gpu_atomic_float(const float* col1, const float* col2, const int n, const int m, unsigned long long* R){
  int row1 = blockIdx.y * blockDim.y + threadIdx.y;
  int row2 = blockIdx.x * blockDim.x + threadIdx.x;
  if (row1 < row2 && row2 < n){
    if ((col1[row1] - col1[row2]) * (col2[row1] - col2[row2]) < 0){
      atomicAdd(R, 1);
    }
  }
}


extern "C" void matrix_Kendall_distance_same_block(double* a, double * b /* not used */, double* c, int* n, int* m, int* m_b){

  size_t dataset_column_size = *n * sizeof(double);
  size_t dataset_float_size = *n * sizeof(float);
  
  size_t reverse_max_size = sizeof(unsigned long long);

  int array_size = *n * *m;

  float* array_new = new float[*n * *m];

  for (int i = 0; i < array_size; ++i) {
    array_new[i] = a[i];
  }

  float* d_array;

  cudaMalloc(&d_array, array_size * sizeof(float));

  cudaMemcpy(d_array, array_new, array_size * sizeof(float), cudaMemcpyHostToDevice);

  unsigned long long* device_R;
  cudaMalloc(&device_R, reverse_max_size);

  cudaMemset(device_R, 0, reverse_max_size);
  unsigned long long host_R = 0;
  for (int col1 = 0; col1 < *m; col1++){
    float* first_column_device_ptr = d_array + col1 * *n;
    //cudaMalloc(&first_column_device_ptr, dataset_float_size);
    //cudaMemcpy(first_column_device_ptr, array_new + col1 * *n, dataset_float_size, cudaMemcpyHostToDevice);
    for (int col2 = col1 + 1; col2 < *m; col2 ++){
      float* second_column_device_ptr = d_array + col2 * *n;
      // std::cout << col1 << " " << col2 << std::endl;
      //cudaMalloc(&second_column_device_ptr, dataset_float_size);
      //cudaMemcpy(second_column_device_ptr, array_new + col2 * *n, dataset_float_size, cudaMemcpyHostToDevice);
      cudaMemset(device_R, 0, reverse_max_size);
      cudaDeviceSynchronize(); 
      int threads = 16;
      int blocks_in_row = (*n + threads - 1) / threads;
      int blocks_in_col = (*n + threads - 1) / threads;

      dim3 THREADS(threads, threads);
      dim3 BLOCKS(blocks_in_row, blocks_in_col);

      Rkendall_gpu_atomic_float<<<BLOCKS, THREADS>>>(first_column_device_ptr, second_column_device_ptr, *n, *m, device_R);
      // gpuErrchk( cudaPeekAtLastError() );
      cudaMemcpy(&host_R, device_R, reverse_max_size, cudaMemcpyDeviceToHost);
      // std::cout << host_R << std::endl;
      c[col1 * *m + col2] = host_R * 2.0f / *n / (*n - 1);
      c[col2 * *m + col1] = c[col1 * *m + col2];

      // cudaFree(second_column_device_ptr);
      // cudaFree(device_R);
    }
    // cudaFree(first_column_device_ptr);
  }
  cudaFree(d_array);
}

extern "C" void matrix_Kendall_distance_different_blocks(double* a, double* b, double* c, int* n, int* m, int* m_b){

  size_t dataset_column_size = *n * sizeof(double);
  size_t reverse_max_size = sizeof(unsigned long long);
  for (int col1 = 0; col1 < *m; col1++){
    double* first_column_device_ptr;
    cudaMalloc(&first_column_device_ptr, dataset_column_size);
    cudaMemcpy(first_column_device_ptr, a + col1 * *n, dataset_column_size, cudaMemcpyHostToDevice);
    // std::cout << col1 << std::endl;
    for (int col2 = 0; col2 < *m_b; col2 ++){
      double* second_column_device_ptr;
      
      cudaMalloc(&second_column_device_ptr, dataset_column_size);
      cudaMemcpy(second_column_device_ptr, b + col2 * *n, dataset_column_size, cudaMemcpyHostToDevice);
      unsigned long long host_R = 0;
      unsigned long long* device_R;
      cudaMalloc(&device_R, reverse_max_size);
      cudaMemcpy(device_R, &host_R, reverse_max_size, cudaMemcpyHostToDevice);
      int threads = 16;
      int blocks_in_row = (*n + threads - 1) / threads;
      int blocks_in_col = (*n + threads - 1) / threads;

      dim3 THREADS(threads, threads);
      dim3 BLOCKS(blocks_in_row, blocks_in_col);

      Rkendall_gpu_atomic<<<BLOCKS, THREADS>>>(first_column_device_ptr, second_column_device_ptr, *n, *m, device_R);

      cudaMemcpy(&host_R, device_R, reverse_max_size, cudaMemcpyDeviceToHost);
      c[col2 * *m + col1] = host_R * 2.0f / *n / (*n - 1);
      // c[col2 * *m + col1] = c[col1 * *m + col2];

      cudaFree(second_column_device_ptr);
      cudaFree(device_R);
    }
    cudaFree(first_column_device_ptr);
  }
}


extern "C" void file_Kendall_distance(double* a, int* n, int* m, char** fout){
  std::ofstream RESULTFILE(*fout, std::ios::binary|std::ios::app);
  size_t dataset_column_size = *n * sizeof(double);
  size_t reverse_max_size = sizeof(unsigned long long);
  for (int col1 = 0; col1 < *m; col1++){
    double* first_column_device_ptr;
    cudaMalloc(&first_column_device_ptr, dataset_column_size);
    cudaMemcpy(first_column_device_ptr, a + col1 * *n, dataset_column_size, cudaMemcpyHostToDevice);
    for (int col2 = col1 + 1; col2 < *m; col2 ++){
      double* second_column_device_ptr;
      cudaMalloc(&second_column_device_ptr, dataset_column_size);
      cudaMemcpy(second_column_device_ptr, a + col2 * *n, dataset_column_size, cudaMemcpyHostToDevice);
      unsigned long long host_R = 0;
      unsigned long long* device_R;
      cudaMalloc(&device_R, reverse_max_size);
      cudaMemcpy(device_R, &host_R, reverse_max_size, cudaMemcpyHostToDevice);
      int threads = 16;
      int blocks_in_row = (*n + threads - 1) / threads;
      int blocks_in_col = (*n + threads - 1) / threads;

      dim3 THREADS(threads, threads);
      dim3 BLOCKS(blocks_in_row, blocks_in_col);

      Rkendall_gpu_atomic<<<BLOCKS, THREADS>>>(first_column_device_ptr, second_column_device_ptr, *n, *m, device_R);
      cudaDeviceSynchronize();

      cudaMemcpy(&host_R, device_R, reverse_max_size, cudaMemcpyDeviceToHost);

      double distance = host_R * 2.0 / *n / (*n - 1);
      RESULTFILE.write((char*)&distance, sizeof(distance));

      cudaFree(second_column_device_ptr);
      cudaFree(device_R);
    }
    cudaFree(first_column_device_ptr);
  }
  RESULTFILE.close();
}
