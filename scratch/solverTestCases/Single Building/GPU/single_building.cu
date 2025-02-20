
#include <stdio.h>
#include "cuda.h"
#include <string.h>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <math.h>
#include <vector>
#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <cuda_runtime.h>
#include <chrono>

#define BLOCKSIZE 1024
#define cudaCheck(x) _cudaCheck(x, #x ,__FILE__, __LINE__)


using namespace std::chrono;
using namespace std;
using std::ofstream;
using std::ifstream;
using std::istringstream;
using std::string;
using std::cerr;
using std::endl;
using std::vector;
using std::cout;
using std::to_string;

__device__ double error;

template<typename T>
void _cudaCheck(T e, const char* func, const char* call, const int line){
    if(e != cudaSuccess){
        printf("\"%s\" at %d in %s\n\treturned %d\n-> %s\n", func, line, call, (int)e, cudaGetErrorString(e));
        exit(EXIT_FAILURE);
    }
}

// Divergence kernel
__global__ void divergence(double *d_u0, double *d_v0, double *d_w0, double *d_R, int alpha1, int  nx, int  ny, int nz, float dx,float dy, float dz){

    int icell_cent = blockDim.x*blockIdx.x+threadIdx.x;
    int k = icell_cent/((nx-1)*(ny-1));
    int j = (icell_cent - k*(nx-1)*(ny-1))/(nx-1);
    int i = icell_cent - k*(nx-1)*(ny-1) - j*(nx-1);
	int icell_face = i + j*nx + k*nx*ny;

    if((i<nx-1)&&(j<ny-1)&&(k<nz-1)){
        d_R[icell_cent] = (-2*pow(alpha1, 2.0))*(((d_u0[icell_face+1]-d_u0[icell_face])/dx)+((d_v0[icell_face + nx]-d_v0[icell_face])/dy)+((d_w0[icell_face + nx*ny]-d_w0[icell_face])/dy));   // Divergence equation
    }
}


__global__ void SOR_RB(double *d_lambda, int nx, int ny, int nz, float omega, float  A, float  B, float  dx, float *d_e, float *d_f, float *d_g, float *d_h, float *d_m, float *d_n, double *d_R, int offset){
    
    int icell_cent = blockDim.x*blockIdx.x+threadIdx.x;
    int k = icell_cent/((nx-1)*(ny-1));
    int j = (icell_cent - k*(nx-1)*(ny-1))/(nx-1);
    int i = icell_cent - k*(nx-1)*(ny-1) - j*(nx-1);
    
    if ( (i > 0) && (i < nx-2) && (j > 0) && (j < ny-2) && (k < nz-2) && (k > 0) && ((i+j+k)%2) == offset ){
        
        d_lambda[icell_cent] = (omega/(d_e[icell_cent]+d_f[icell_cent]+d_g[icell_cent]+d_h[icell_cent]+d_m[icell_cent]+d_n[icell_cent]))*(d_e[icell_cent]*d_lambda[icell_cent+1]+d_f[icell_cent]*d_lambda[icell_cent-1]+d_g[icell_cent]*d_lambda[icell_cent + (nx-1)]+d_h[icell_cent]*d_lambda[icell_cent - (nx-1)]+d_m[icell_cent]*d_lambda[icell_cent + (nx-1)*(ny-1)]+d_n[icell_cent]*d_lambda[icell_cent - (nx-1)*(ny-1)]-d_R[icell_cent])+(1-omega)*d_lambda[icell_cent];    /// SOR formulation
    }
}

__global__ void assign_lambda_to_lambda_old(double *d_lambda, double *d_lambda_old, int nx, int ny, int nz) {
    
    int ii = blockDim.x*blockIdx.x+threadIdx.x;
    
    if(ii < (nz-1)*(ny-1)*(nx-1)) {
        d_lambda_old[ii] = d_lambda[ii];
    }
    
}

__global__ void applyNeumannBC(double *d_lambda, int nx, int ny) {
    // Neumann boundary condition (lambda (@k=0) = lambda (@k=1))
    int ii = blockDim.x*blockIdx.x+threadIdx.x;
    
    if(ii < nx*ny) {
      d_lambda[ii] = d_lambda[ii + 1*(nx-1)*(ny-1)];
    }
}

__global__ void calculateError(double *d_lambda, double *d_lambda_old, int nx, int ny, int nz, double *d_value, double *d_bvalue){


	int d_size = (nx-1)*(ny-1)*(nz-1);
	int ii = blockDim.x*blockIdx.x+threadIdx.x;
	int numblocks = (d_size/BLOCKSIZE) +1;

	if (ii < d_size){
	    d_value[ii] = fabs(d_lambda[ii] - d_lambda_old[ii])/((nx-1)*(ny-1)*(nz-1));
	}
	__syncthreads();
        double sum = 0.0;
	if (threadIdx.x > 0){ 
	    return;
	}
	if (threadIdx.x == 0) {
	     for (int j=0; j<BLOCKSIZE; j++){
		int index = blockIdx.x*blockDim.x+j;
		if (index<d_size){
			sum += d_value[index]; 
		}
	     }
	}
	
	__syncthreads();
	d_bvalue[blockIdx.x] = sum;

	if (ii>0){
	    return;
	}

	error = 0.0;
	if (ii==0){
	    for (int k =0; k<numblocks; k++){
		error += d_bvalue[k];
	    }
	}

 }

// Euler Final Velocity kernel
__global__ void finalVelocity(double *d_u0, double *d_v0, double *d_w0, double *d_lambda, double *d_u, double *d_v,double *d_w, int *d_icellflag, int alpha1, int alpha2, float dx, float dy, float dz, int  nx, int  ny, int nz){

    int icell_face = blockDim.x*blockIdx.x+threadIdx.x;
    int k = icell_face/(nx*ny);
    int j = (icell_face - k*nx*ny)/nx;
    int i = icell_face - k*nx*ny - j*nx;
	int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values

    if((i<nx)&&(j<ny)&&(k<nz)){
		
		d_u[icell_face] = d_u0[icell_face];
        d_v[icell_face] = d_v0[icell_face];
        d_w[icell_face] = d_w0[icell_face];

	}

	
	if ((i > 0) && (i < nx-1) && (j > 0) && (j < ny-1) && (k < nz-1) && (k > 0)) {

		d_u[icell_face] = d_u0[icell_face]+(1/(2*pow(alpha1, 2.0)*dx))*(d_lambda[icell_cent]-d_lambda[icell_cent-1]);
        d_v[icell_face] = d_v0[icell_face]+(1/(2*pow(alpha1, 2.0)*dy))*(d_lambda[icell_cent]-d_lambda[icell_cent - (nx-1)]);
        d_w[icell_face] = d_w0[icell_face]+(1/(2*pow(alpha2, 2.0)*dz))*(d_lambda[icell_cent]-d_lambda[icell_cent - (nx-1)*(ny-1)]);

	}

	
	if ((i > 0) && (i < nx-1) && (j > 0) && (j < ny-1) && (k < nz-1) && (k > 0) && (d_icellflag[icell_cent] == 0) ) {
		d_u[icell_face] = 0;
		d_u[icell_face+1] = 0;
		d_v[icell_face] = 0;
		d_v[icell_face+nx] = 0;
		d_w[icell_face] = 0;
		d_w[icell_face+nx*ny] = 0;
		
    }
}
__global__ void SOR_iteration (double *d_lambda, double *d_lambda_old, int nx, int ny, int nz, float omega, float  A, float  B, float  dx, float *d_e, float *d_f, float *d_g, float *d_h, float *d_m, float *d_n, double *d_R, int itermax, double tol, double *d_value, double *d_bvalue, double *d_u0, double *d_v0, double *d_w0,int alpha1, int alpha2, float dy, float dz, double *d_u, double *d_v, double *d_w, int *d_icellflag) {
    int iter = 0;
    error = 1.0;

    // Calculate divergence of initial velocity field
    dim3 numberOfThreadsPerBlock(BLOCKSIZE,1,1);
    dim3 numberOfBlocks(ceil(((nx-1)*(ny-1)*(nz-1))/(double) (BLOCKSIZE)),1,1);
    // Invoke divergence kernel
    divergence<<<numberOfBlocks,numberOfThreadsPerBlock>>>(d_u0,d_v0,d_w0,d_R,alpha1,nx,ny,nz,dx,dy,dz);

    // Iterate untill convergence is reached
    while ( (iter < itermax) && (error > tol)) {
        
  		// Save previous iteration values for error calculation 
        assign_lambda_to_lambda_old<<<numberOfBlocks,numberOfThreadsPerBlock>>>(d_lambda, d_lambda_old, nx, ny, nz);
		cudaDeviceSynchronize();
        // SOR part
        int offset = 0;   // red nodes
		// Invoke red-black SOR kernel for red nodes
        SOR_RB<<<numberOfBlocks,numberOfThreadsPerBlock>>>(d_lambda, nx, ny, nz, omega, A, B, dx, d_e, d_f, d_g, d_h, d_m, d_n, d_R, offset);
        cudaDeviceSynchronize();
		offset = 1;    // black nodes
		// Invoke red-black SOR kernel for black nodes
        SOR_RB<<<numberOfBlocks,numberOfThreadsPerBlock>>>(d_lambda, nx, ny, nz, omega, A, B, dx, d_e, d_f, d_g, d_h, d_m, d_n, d_R,offset);
        cudaDeviceSynchronize();
		dim3 numberOfBlocks2(ceil(((nx-1)*(ny-1))/(double) (BLOCKSIZE)),1,1);
		// Invoke kernel to apply Neumann boundary condition (lambda (@k=0) = lambda (@k=1))
        applyNeumannBC<<<numberOfBlocks2,numberOfThreadsPerBlock>>>(d_lambda, nx, ny);
        cudaDeviceSynchronize();
        // Error calculation
		calculateError<<<numberOfBlocks,numberOfThreadsPerBlock>>>(d_lambda,d_lambda_old, nx, ny, nz, d_value,d_bvalue);
		cudaDeviceSynchronize();

        iter += 1;
        
    }
    printf("number of iteration = %d\n", iter);
    printf("error = %2.9f\n", error);
	dim3 numberOfBlocks3(ceil((nx*ny*nz)/(double) (BLOCKSIZE)),1,1);
    // Invoke final velocity (Euler) kernel
    finalVelocity<<<numberOfBlocks3,numberOfThreadsPerBlock>>>(d_u0,d_v0,d_w0,d_lambda,d_u,d_v,d_w,d_icellflag,alpha1,alpha2,dx,dy,dz,nx,ny,nz);
}



int main(int argc, const char * argv[]) {
    
    int nx = 40;    /// Number of cells in x-dir 
    int ny = 40;    /// Number of cells in y-dir
    int nz = 40;    /// Number of cells in z-dir
    nx += 1;        /// +1 for Staggered grid
    ny += 1;        /// +1 for Staggered grid
    nz += 2;        /// +2 for staggered grid and ghost cell
	long numcell_cent = (nx-1)*(ny-1)*(nz-1);         /// Total number of cell-centered values in domain
    long numface_cent = nx*ny*nz;                     /// Total number of face-centered values in domain
    
    /// Grid resolution
    float dx = 5.0;
    float dy = 5.0;
    float dz = 5.0;
    
    int alpha1 = 1;        /// Gaussian precision moduli
    int alpha2 = 1;        /// Gaussian precision moduli
    float eta = pow(alpha1/alpha2, 2.0);
    float A = pow(dx/dy, 2.0);
    float B = eta*pow(dx/dz, 2.0);
    float tol = 1e-9;     /// Error tolerance
    float omega = 1.78;   /// Over-relaxation factor
    int itermax = 500;    /// Maximum number of iterations
    
    /// Declare face-centered positions
    float *x, *y, *z;
    x = new float [nx];
    y = new float [ny];
    z = new float [nz];  

    /// Declare coefficients for SOR solver
    float *e, *f, *g, *h, *m, *n;
    e = new float [numcell_cent];
    f = new float [numcell_cent];
    g = new float [numcell_cent];
    h = new float [numcell_cent];
    m = new float [numcell_cent];
    n = new float [numcell_cent];

	float *d_e, *d_f, *d_g, *d_h, *d_m, *d_n;
    cudaMalloc((void **) &d_e, numcell_cent * sizeof(float));
    cudaMalloc((void **) &d_f, numcell_cent * sizeof(float));
    cudaMalloc((void **) &d_g, numcell_cent * sizeof(float));
    cudaMalloc((void **) &d_h, numcell_cent * sizeof(float));
    cudaMalloc((void **) &d_m, numcell_cent * sizeof(float));
    cudaMalloc((void **) &d_n, numcell_cent * sizeof(float));

    /// Declaration of initial wind components (u0,v0,w0)
    double *u0, *v0, *w0;
    u0 = new double [numface_cent];
    v0 = new double [numface_cent];
    w0 = new double [numface_cent];
    
    
    double *R, *d_R;              //!> Divergence of initial velocity field
    R = new double [numcell_cent];
    cudaMalloc((void **) &d_R, numcell_cent * sizeof(double));    

    /// Declaration of final velocity field components (u,v,w)
    double *u, *v, *w;
    u = new double [numface_cent];
    v = new double [numface_cent];
    w = new double [numface_cent];

    // Declare Lagrange multipliers
    /// Declaration of Lagrange multipliers
    double *lambda, *lambda_old, *d_lambda, *d_lambda_old;
    lambda = new double [numcell_cent];
    lambda_old = new double [numcell_cent];
    cudaMalloc((void **) &d_lambda, numcell_cent * sizeof(double));
    cudaMalloc((void **) &d_lambda_old, numcell_cent * sizeof(double));

    int numblocks = (numcell_cent/BLOCKSIZE)+1;
    double *value, *bvalue;
    value = new double [numcell_cent];
    bvalue = new double [numblocks];    
    
    
    for ( int i = 0; i < nx-1; i++){
        x[i] = (i+0.5)*dx;         /// Location of face centers in x-dir
    }
    for ( int j = 0; j < ny-1; j++){
        y[j] = (j+0.5)*dy;         /// Location of face centers in y-dir
    }
    for ( int k = 0; k < nz-1; k++){
        z[k] = (k-0.5)*dz;         /// Location of face centers in z-dir
    }


    float z0 = 0.1;                 /// Surface roughness
    float z_ref = 10.0;             /// Height of the measuring sensor (m)
    float U_ref = 5.0;              /// Measured velocity at the sensor height (m/s)
    float H = 20.0;                 /// Building height
    float W = 20.0;                 /// Building width
    float L = 20.0;                 /// Building length
    float x_start = 90.0;           /// Building start location in x-direction
    float y_start = 90.0;           /// Building start location in y-direction
    float i_start = std::round(x_start/dx);     /// Index of building start location in x-direction
    float i_end = std::round((x_start+L)/dx);   /// Index of building end location in x-direction
    float j_start = std::round(y_start/dy);     /// Index of building start location in y-direction
    float j_end = std::round((y_start+W)/dy);   /// Index of building end location in y-direction 
    float k_end = std::round(H/dz);             /// Index of building end location in z-direction
    int *icellflag, *d_icellflag;
    icellflag = new int [numcell_cent];       /// Cell index flag (0 = building, 1 = fluid)

    std::cout << "i_start:" << i_start << "\n";   // Print the number of iterations
    std::cout << "i_end:" << i_end << "\n";       // Print the number of iterations
    std::cout << "j_start:" << j_start << "\n";   // Print the number of iterations
    std::cout << "j_end:" << j_end << "\n";       // Print the number of iterations    
    std::cout << "k_end:" << k_end << "\n";       // Print the number of iterations 

    for ( int k = 0; k < nz-1; k++){
        for (int j = 0; j < ny-1; j++){
            for (int i = 0; i < nx-1; i++){

				int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);            /// Lineralized index for cell centered values
                e[icell_cent] = f[icell_cent] = g[icell_cent] = h[icell_cent] = m[icell_cent] = n[icell_cent] = 1.0;  /// Assign initial values to the coefficients for SOR solver
				icellflag[icell_cent] = 1;                                  /// Initialize all cells to fluid	
				lambda[icell_cent] = lambda_old[icell_cent] = 0.0;
			}
		}    
	}	

    for ( int k = 1; k < nz; k++){
        for (int j = 0; j < ny; j++){
            for (int i = 0; i < nx; i++){
				
				int icell_face = i + j*nx + k*nx*ny;   /// Lineralized index for cell faced values                                
                /// Define logarithmic wind profile
                u0[icell_face] = U_ref*(log((z[k]+z0)/z0)/log((z_ref+z0)/z0));
				v0[icell_face] = w0 [icell_face] = 0.0;         /// Perpendicular wind direction

            }
        }
    }

    for (int k = 0; k < k_end+1; k++){
        for (int j = j_start; j < j_end; j++){
            for (int i = i_start; i < i_end; i++){

                int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values
				icellflag[icell_cent] = 0;                         /// Set cell index flag to building

			}
		}
    }

    for (int j = 0; j < ny-1; j++){
        for (int i = 0; i < nx-1; i++){
            int icell_cent = i + j*(nx-1);   /// Lineralized index for cell centered values
            icellflag[icell_cent] = 0.0;
        }
    }

   
    for (int k = 0; k < nz; k++){
        for (int j = 0; j < ny; j++){
            for (int i = 0; i < nx; i++){
				int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values
                int icell_face = i + j*nx + k*nx*ny;   /// Lineralized index for cell faced values 
				if (icellflag[icell_cent] == 0) {
					u0[icell_face] = 0.0;                    /// Set velocity inside the building to zero
					u0[icell_face+1] = 0.0;
					v0[icell_face] = 0.0;                    /// Set velocity inside the building to zero
					v0[icell_face+nx] = 0.0;
					w0[icell_face] = 0.0;                    /// Set velocity inside the building to zero
					w0[icell_face+nx*ny] = 0.0;
				}
	     	}
		}
	}


    auto start = std::chrono::high_resolution_clock::now(); // Start recording execution time

	cudaMalloc((void **) &d_icellflag, numcell_cent * sizeof(int));
	cudaMemcpy(d_icellflag,icellflag,numcell_cent*sizeof(int),cudaMemcpyHostToDevice);
    // Allocate GPU memory
    double *d_u0, *d_v0, *d_w0;
    cudaMalloc((void **) &d_u0,numface_cent*sizeof(double));
    cudaMalloc((void **) &d_v0,numface_cent*sizeof(double));
    cudaMalloc((void **) &d_w0,numface_cent*sizeof(double));
    // Initialize GPU input/output
    cudaMemcpy(d_u0,u0,numface_cent*sizeof(double),cudaMemcpyHostToDevice);
    cudaMemcpy(d_v0,v0,numface_cent*sizeof(double),cudaMemcpyHostToDevice);
    cudaMemcpy(d_w0,w0,numface_cent*sizeof(double),cudaMemcpyHostToDevice);
    cudaMemcpy(d_R,R,numcell_cent*sizeof(double),cudaMemcpyHostToDevice);

    /// Boundary condition for building edges
    for (int k = 1; k < nz-2; k++){
        for (int j = 1; j < ny-2; j++){
            for (int i = 1; i < nx-2; i++){
                int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values
				if (icellflag[icell_cent] != 0) {
					
					/// Wall bellow
					if (icellflag[icell_cent-(nx-1)*(ny-1)]==0) {
		    			n[icell_cent] = 0.0; 

					}
					/// Wall above
					if (icellflag[icell_cent+(nx-1)*(ny-1)]==0) {
		    			m[icell_cent] = 0.0;
					}
					/// Wall in back
					if (icellflag[icell_cent-1]==0){
						f[icell_cent] = 0.0; 
					}
					/// Wall in front
					if (icellflag[icell_cent+1]==0){
						e[icell_cent] = 0.0; 
					}
					/// Wall on right
					if (icellflag[icell_cent-(nx-1)]==0){
						h[icell_cent] = 0.0;
					}
					/// Wall on left
					if (icellflag[icell_cent+(nx-1)]==0){
						g[icell_cent] = 0.0; 
					}
				}
			}
		}
	}

    /// New boundary condition implementation
    for (int k = 1; k < nz-1; k++){
        for (int j = 0; j < ny-1; j++){
            for (int i = 0; i < nx-1; i++){
				int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values
				e[icell_cent] = e[icell_cent]/(dx*dx);
				f[icell_cent] = f[icell_cent]/(dx*dx);
				g[icell_cent] = g[icell_cent]/(dy*dy);
				h[icell_cent] = h[icell_cent]/(dy*dy);
				m[icell_cent] = m[icell_cent]/(dz*dz);
				n[icell_cent] = n[icell_cent]/(dz*dz);
			}
		}
	}
	
	double *d_value,*d_bvalue;
	float *d_x,*d_y,*d_z;
	cudaMalloc((void **) &d_value,numcell_cent*sizeof(double));
	cudaMalloc((void **) &d_bvalue,numblocks*sizeof(double));
	cudaMalloc((void **) &d_x,nx*sizeof(float));
	cudaMalloc((void **) &d_y,ny*sizeof(float));
	cudaMalloc((void **) &d_z,nz*sizeof(float));
	cudaMemcpy(d_value , value , numcell_cent * sizeof(double) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_bvalue , bvalue , numblocks * sizeof(double) , cudaMemcpyHostToDevice);      
	cudaMemcpy(d_e , e , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_f , f , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_g , g , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_h , h , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_m , m , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_n , n , numcell_cent * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_x , x , nx * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_y , y , ny * sizeof(float) , cudaMemcpyHostToDevice);
	cudaMemcpy(d_z , z , nz * sizeof(float) , cudaMemcpyHostToDevice);
	
	double *d_u, *d_v, *d_w;
	cudaMalloc((void **) &d_u,numface_cent*sizeof(double));
	cudaMalloc((void **) &d_v,numface_cent*sizeof(double));
	cudaMalloc((void **) &d_w,numface_cent*sizeof(double));

    /////////////////////////////////////////////////
    //                 SOR solver              //////
    /////////////////////////////////////////////////
    
    cudaMemcpy(d_lambda , lambda , numcell_cent * sizeof(double) , cudaMemcpyHostToDevice);
    cudaMemcpy(d_lambda_old , lambda_old , numcell_cent * sizeof(double) , cudaMemcpyHostToDevice);
    // Invoke the main (mother) kernel
    SOR_iteration<<<1,1>>>(d_lambda,d_lambda_old, nx, ny, nz, omega, A, B, dx, d_e, d_f, d_g, d_h, d_m, d_n, d_R,itermax,tol,d_value,d_bvalue,d_u0,d_v0,d_w0,alpha1,alpha2,dy,dz,d_u,d_v,d_w,d_icellflag);
    cudaCheck(cudaGetLastError()); 
    
    cudaMemcpy (lambda , d_lambda , numcell_cent * sizeof(double) , cudaMemcpyDeviceToHost);
    cudaMemcpy(u,d_u,numface_cent*sizeof(double),cudaMemcpyDeviceToHost);
    cudaMemcpy(v,d_v,numface_cent*sizeof(double),cudaMemcpyDeviceToHost);
    cudaMemcpy(w,d_w,numface_cent*sizeof(double),cudaMemcpyDeviceToHost);

    cudaFree (d_lambda);
    cudaFree (d_e);
    cudaFree (d_f);
    cudaFree (d_g);
    cudaFree (d_h);
    cudaFree (d_m);
    cudaFree (d_n);
    cudaFree (d_R);
    cudaFree (d_value);
    cudaFree (d_bvalue);
    cudaFree (d_u0);
    cudaFree (d_v0);
    cudaFree (d_w0);
    cudaFree (d_u);
    cudaFree (d_v);
    cudaFree (d_w);
    cudaFree (d_x);
    cudaFree (d_y);
    cudaFree (d_z);
    cudaFree (d_icellflag);

    auto finish = std::chrono::high_resolution_clock::now();  // Finish recording execution time
    std::chrono::duration<double> elapsed = finish - start;
    std::cout << "Elapsed time: " << elapsed.count() << " s\n";   // Print out elapsed execution time    
    
	/// Declare cell center positions
    float *x_out, *y_out, *z_out;
    x_out = new float [nx-1];
    y_out = new float [ny-1];
    z_out = new float [nz-1];


	for ( int i = 0; i < nx-1; i++) {
		x_out[i] = (i+0.5)*dx;         /// Location of cell centers in x-dir
	}
    for ( int j = 0; j < ny-1; j++){
        y_out[j] = (j+0.5)*dy;         /// Location of cell centers in y-dir
    }
    for ( int k = 0; k < nz-1; k++){
        z_out[k] = (k-0.5)*dz;         /// Location of cell centers in z-dir
    }

	/// Declare output velocity field arrays
    double ***u_out, ***v_out, ***w_out;
    u_out = new double** [nx-1];
    v_out = new double** [nx-1];
    w_out = new double** [nx-1];
	
	for (int i = 0; i < nx-1; i++){
		u_out[i] = new double* [ny-1];
		v_out[i] = new double* [ny-1];
		w_out[i] = new double* [ny-1];
		for (int j = 0; j < ny-1; j++){
			u_out[i][j] = new double [nz-1];
			v_out[i][j] = new double [nz-1];
			w_out[i][j] = new double [nz-1];
		}
	}


	for (int k = 0; k < nz-1; k++){
        for (int j = 0; j < ny-1; j++){
            for (int i = 0; i < nx-1; i++){
                int icell_face = i + j*nx + k*nx*ny;   /// Lineralized index for cell faced values 
				u_out[i][j][k] = 0.5*(u[icell_face+1]+u[icell_face]);
				v_out[i][j][k] = 0.5*(v[icell_face+nx]+v[icell_face]);
				w_out[i][j][k] = 0.5*(w[icell_face+nx*ny]+w[icell_face]);
			}
		}	
	}

    // Write data to file
    ofstream outdata1;
    outdata1.open("Final velocity.dat");
    if( !outdata1 ) {                 // File couldn't be opened
        cerr << "Error: file could not be opened" << endl;
        exit(1);
    }
    // Write data to file
    for (int k = 0; k < nz; k++){
        for (int j = 0; j < ny; j++){
            for (int i = 0; i < nx; i++){
				//int icell_cent = i + j*(nx-1) + k*(nx-1)*(ny-1);   /// Lineralized index for cell centered values
				int icell_face = i + j*nx + k*nx*ny;   /// Lineralized index for cell faced values
                outdata1 << "\t" << i << "\t" << j << "\t" << k << "\t \t"<< x[i] << "\t \t" << y[j] << "\t \t" << z[k] << "\t \t"<< "\t \t" << u[icell_face] <<"\t \t"<< "\t \t"<<v[icell_face]<<"\t \t"<< "\t \t"<<w[icell_face]<< endl;   
}
        }
    }
    outdata1.close();

    // Write data to file
    ofstream outdata;
    outdata.open("Final velocity, cell-centered.dat");
    if( !outdata ) {                 // File couldn't be opened
        cerr << "Error: file could not be opened" << endl;
        exit(1);
    }
    // Write data to file
    for (int k = 0; k < nz-1; k++){
        for (int j = 0; j < ny-1; j++){
            for (int i = 0; i < nx-1; i++){
                outdata << "\t" << i << "\t" << j << "\t" << k << "\t"<< x_out[i] << "\t" << y_out[j] << "\t" << z_out[k] << "\t" << u_out[i][j][k] << "\t" << v_out[i][j][k] << "\t" << w_out[i][j][k] 					<< endl;   
			}
		}
	}
    outdata.close();
   
    return 0;
}


